//
//  HYMemoryCache.m
//  Pods
//
//  Created by fangyuxi on 16/4/5.
//
//

#import "HYMemoryCache.h"
#import <pthread.h>
#import <libkern/OSAtomic.h>

static NSString *const queueNamePrefix = @"com.HYMemCache.";
static OSSpinLock mutexLock;

#pragma mark lock

static inline void lock()
{
    OSSpinLockLock(&mutexLock);
}

static inline void unLock()
{
    OSSpinLockUnlock(&mutexLock);
}

#pragma mark _HYMemoryCacheItem

@interface _HYMemoryCacheItem : NSObject
{
    @package //need access in this framework
    id _key;
    id _object;
    NSUInteger _cost;
    NSTimeInterval _age;
}

- (NSComparisonResult)compare:(_HYMemoryCacheItem *)cacheItem;

@end

@implementation _HYMemoryCacheItem

//not implement LRU,just old objects first
- (NSComparisonResult)compare:(_HYMemoryCacheItem *)cacheItem
{
    if (!cacheItem) return NSOrderedSame;
    
    if (_age < cacheItem->_age)
    {
        return NSOrderedAscending;
    }
    else if (_age > cacheItem->_age)
    {
        return NSOrderedDescending;
    }
    return NSOrderedSame;
}

@end

#pragma mark HYMemoryCache

@interface HYMemoryCache ()
{
    CFMutableDictionaryRef _objectDic;
}

@property (nonatomic, strong) dispatch_queue_t concurrentQueue;
@property (nonatomic, copy, readwrite) NSString *name;

inline _HYMemoryCacheItem * p_itemForKey(CFMutableDictionaryRef objectDic,  id key);
inline NSArray * p_keySortedByInCacheDate(CFMutableDictionaryRef _objectDic);

@end

@implementation HYMemoryCache

@synthesize totalCostNow = _totalCostNow;
@synthesize costLimit = _costLimit;
@synthesize maxAge = _maxAge;
@synthesize trimToMaxAgeInterval = _trimToMaxAgeInterval;

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    CFRelease(_objectDic);
}

- (instancetype)init
{
    return [self initWithName:@"HYMemoryCache"];
}

- (instancetype)initWithName:(NSString *)name
{
    self = [super init];
    if (self)
    {
        mutexLock = OS_SPINLOCK_INIT;
        self.name = name;
        _concurrentQueue = dispatch_queue_create([[NSString stringWithFormat:@"%@%@", queueNamePrefix, name] UTF8String], DISPATCH_QUEUE_CONCURRENT);
        
        _objectDic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0,&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        
        _removeObjectWhenAppEnterBackground = YES;
        _removeObjectWhenAppReceiveMemoryWarning = YES;
        _totalCostNow = 0;
        _costLimit = 0;
        _maxAge = 0.0f;
        _trimToMaxAgeInterval = 30.0f;
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveEnterBackgroundNotification:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveMemoryWarningNotification:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        
        return self;
    }
    return nil;
}



#pragma mark notification

- (void)didReceiveMemoryWarningNotification:(NSNotification *)notification
{
    if (self.removeObjectWhenAppReceiveMemoryWarning)
    {
        [self removeAllObjectWithBlock:^(HYMemoryCache * _Nonnull cache) {
            
        }];
    }
}

- (void)didReceiveEnterBackgroundNotification:(NSNotification *)notification
{
    if (self.removeObjectWhenAppEnterBackground)
    {
        [self removeAllObjectWithBlock:^(HYMemoryCache * _Nonnull cache) {
            
        }];
    }
}

#pragma mark set value

- (void)setObject:(id)object
           forKey:(id)key
        withBlock:(__nullable HYMemoryCacheObjectBlock)block
{
    __weak HYMemoryCache *weakSelf = self;
    dispatch_async(_concurrentQueue, ^{
        
        HYMemoryCache *stronglySelf = weakSelf;
        
        [self setObject:object forKey:key];
        
        if (block)
        {
            block(stronglySelf, key, object);
        }
    });
}

- (void)setObject:(id)object
           forKey:(id)key
         withCost:(NSUInteger)cost
        withBlock:(__nullable HYMemoryCacheObjectBlock)block
{
    __weak HYMemoryCache *weakSelf = self;
    dispatch_async(_concurrentQueue, ^{
       
        HYMemoryCache *stronglySelf = weakSelf;
        
        [self setObject:object forKey:key withCost:cost];
        
        if (block)
        {
            block(stronglySelf, key, object);
        }
    });
}

- (void)setObject:(id)object
           forKey:(id)key
{
    [self setObject:object forKey:key withCost:0];
}

- (void)setObject:(id)object
           forKey:(id)key
         withCost:(NSUInteger)cost
{
    if (!object || !key) return;
    
    _HYMemoryCacheItem *item = p_itemForKey(_objectDic, key);
    lock();
    if (item)
    {
        item->_object = object;
        item->_key = key;
        item->_cost = cost;
        item->_age = CACurrentMediaTime();
        _totalCostNow = cost > item->_cost ? cost - item->_cost : item->_cost - cost;
    }
    else
    {
        _HYMemoryCacheItem *item = [_HYMemoryCacheItem new];
        item->_object = object;
        item->_key = key;
        item->_cost = cost;
        item->_age = CACurrentMediaTime();
        _totalCostNow += cost;
        CFDictionarySetValue(_objectDic, (__bridge const void *)key, (__bridge const void *)item);
    }
    unLock();
}

#pragma mark get value

- (id __nullable )objectForKey:(id)key
{
    if (!key) return nil;
    lock();
    NSTimeInterval maxAge = _maxAge;
    unLock();
    
    _HYMemoryCacheItem *item = p_itemForKey(_objectDic, key);
    
    NSTimeInterval now = CACurrentMediaTime();
    
    //即使对象存在，但是超出了maxAge没来得及清理，那么也是NO
    if (item != nil && maxAge==0 ? YES : now - item->_age < maxAge)
        return item->_object;
    return nil;
}

- (void)objectForKey:(NSString *)key
           withBlock:(HYMemoryCacheObjectBlock)block
{
    __weak HYMemoryCache *weakSelf = self;
    dispatch_async(_concurrentQueue, ^{
        
        HYMemoryCache *stronglySelf = weakSelf;
        
        id object = [self objectForKey:key];
        
        if (block)
        {
            block(stronglySelf, key, object);
        }
    });
}

_HYMemoryCacheItem * p_itemForKey(CFMutableDictionaryRef objectDic,  id key)
{
    lock();
    _HYMemoryCacheItem *item = CFDictionaryGetValue(objectDic, (__bridge const void *)key);
    unLock();
    return item;
}

#pragma mark remove value

- (void)removeObjectForKey:(NSString *)key
                 withBlock:(__nullable HYMemoryCacheObjectBlock)block
{
    __weak HYMemoryCache *weakSelf = self;
    dispatch_async(_concurrentQueue, ^{
        
        HYMemoryCache *stronglySelf = weakSelf;
        
        _HYMemoryCacheItem *item = p_itemForKey(_objectDic, key);
        [self removeObjectForKey:key];
        
        if (block)
        {
            block(stronglySelf, key, item);
        }
    });
}

- (void)removeObjectForKey:(id)key
{
    if(!key) return;
    
    lock();
    _HYMemoryCacheItem *item = CFDictionaryGetValue(_objectDic, (__bridge const void *)key);
    if (item)
    {
        _totalCostNow -= item->_cost;
        CFDictionaryRemoveValue(_objectDic, (__bridge const void *)key);
    }
    unLock();
}


- (void)removeAllObjectWithBlock:(__nullable HYMemoryCacheBlock)block
{
    __weak HYMemoryCache *weakSelf = self;
    dispatch_async(_concurrentQueue, ^{
        
        HYMemoryCache *stronglySelf = weakSelf;
        
        [self removeAllObject];
        
        if (block)
        {
            block(stronglySelf);
        }
    });
}

- (void)removeAllObject
{
    lock();
    _totalCostNow = 0;
    CFDictionaryRemoveAllValues(_objectDic);
    unLock();
}

#pragma mark contained value

- (BOOL)containsObjectForKey:(id)key
{
    if (!key) return NO;
    lock();
    NSTimeInterval maxAge = _maxAge;
    unLock();
    
    _HYMemoryCacheItem *item = p_itemForKey(_objectDic, key);
    NSTimeInterval now = CACurrentMediaTime();
    //即使对象存在，但是超出了maxAge没来得及清理，那么也是NO
    return item != nil && maxAge==0 ? YES : now - item->_age < maxAge;
}

#pragma mark trim value

- (void)trimToCost:(NSUInteger)cost block:(nullable HYMemoryCacheBlock)block
{
    __weak HYMemoryCache *weakSelf = self;
    dispatch_async(_concurrentQueue, ^{
        
        HYMemoryCache *stronglySelf = weakSelf;
        
        [self p_trimToCost:cost];
        
        if (block)
        {
            block(stronglySelf);
        }
    });
}

//not implement LRU,just old objects first
- (void)p_trimToCost:(NSUInteger)cost
{
    NSUInteger totalCost = 0;
    lock();
    totalCost = _totalCostNow;
    unLock();
    if (totalCost <= cost) return;
    
    NSArray *keys = p_keySortedByInCacheDate(_objectDic);
    
    for (NSString *key in [keys reverseObjectEnumerator])
    {
        [self removeObjectForKey:key];// old objects first
        
        lock();
        totalCost = _totalCostNow;
        unLock();
        
        if (totalCost <= cost)
            break;
    }
}

- (void)trimToCostLimitWithBlock:(nullable HYMemoryCacheBlock)block
{
    __weak HYMemoryCache *weakSelf = self;
    dispatch_async(_concurrentQueue, ^{
        
        HYMemoryCache *stronglySelf = weakSelf;
        
        [self p_trimToCostLimit];
        
        if (block)
        {
            block(stronglySelf);
        }
    });
}

- (void)p_trimToCostLimit
{
    lock();
    NSUInteger costLimit = _costLimit;
    NSUInteger nowCost = _totalCostNow;
    unLock();
    
    if (nowCost < costLimit) return;
    if (costLimit == 0) return;
    
    [self p_trimToCost:costLimit];
}

- (void)p_trimToAgeLimitRecursively
{
    lock();
    NSTimeInterval maxAge = _maxAge;
    NSTimeInterval trimInterval = _trimToMaxAgeInterval;
    unLock();
    
    if (maxAge == 0) return;
    
    NSArray *keys = p_keySortedByInCacheDate(_objectDic);
    
    for (NSString *key in [keys reverseObjectEnumerator])// old objects first
    {
        _HYMemoryCacheItem *item = p_itemForKey(_objectDic, key);
        if (item)
        {
            NSTimeInterval now = CACurrentMediaTime();
            NSTimeInterval inTime = item->_age;
            
            if (now - inTime >= maxAge)
            {
                [self removeObjectForKey:key];
            }
            else
            {
                break;
            }
        }
    }
    
    dispatch_time_t interval = dispatch_time(DISPATCH_TIME_NOW, (int64_t)((trimInterval == 0 ? maxAge:trimInterval) * NSEC_PER_SEC));
    
    __weak HYMemoryCache *weakSelf = self;
    dispatch_after(interval, _concurrentQueue, ^{
       
        HYMemoryCache *stronglySelf = weakSelf;
        [stronglySelf p_trimToAgeLimitRecursively];
    });
}

NSArray * p_keySortedByInCacheDate(CFMutableDictionaryRef _objectDic)
{
    lock();
    NSMutableDictionary *dic = (__bridge NSMutableDictionary *)_objectDic;
    NSArray *keys = [dic keysSortedByValueUsingSelector:@selector(compare:)];
    unLock();
    return keys;
}

#pragma mark getter setter

- (NSUInteger)totalCostNow
{
    lock();
    NSUInteger cost = _totalCostNow;
    unLock();
    return cost;
}

- (NSUInteger)costLimit
{
    lock();
    NSUInteger cost = _costLimit;
    unLock();
    return cost;
}

- (void)setCostLimit:(NSUInteger)costLimit
{
    lock();
    _costLimit = costLimit;
    unLock();
}

- (void)setMaxAge:(NSTimeInterval)maxAge
{
    lock();
    _maxAge = maxAge;
    unLock();
    
    [self p_trimToAgeLimitRecursively];
}

- (NSTimeInterval)maxAge
{
    lock();
    NSTimeInterval age = _maxAge;
    unLock();
    return age;
}

- (void)setTrimToMaxAgeInterval:(NSTimeInterval)trimToMaxAgeInterval
{
    lock();
    _trimToMaxAgeInterval = trimToMaxAgeInterval;
    unLock();
}

- (NSTimeInterval)trimToMaxAgeInterval
{
    lock();
    NSTimeInterval trimTime = _trimToMaxAgeInterval;
    unLock();
    return trimTime;
}

@end





