from libc.stdint cimport uint32_t, uint64_t
from libcpp cimport bool as cpp_bool
from std_memory cimport shared_ptr
from libcpp.map cimport map as cpp_map
from libcpp.vector cimport vector
from libcpp.unordered_set cimport unordered_set


from status cimport Status

from db cimport DB
from cache cimport Cache

cdef extern from "rocksdb/utilities/memory_util.h" namespace "rocksdb":
    ctypedef enum MemoryUtil_UsageType "rocksdb::MemoryUtil::UsageType":
        kMemTableTotal "rocksdb::MemoryUtil::UsageType::kMemTableTotal"
        kMemTableUnFlushed "rocksdb::MemoryUtil::UsageType::kMemTableUnFlushed"
        kTableReadersTotal "rocksdb::MemoryUtil::UsageType::kTableReadersTotal"
        kCacheTotal "rocksdb::MemoryUtil::UsageType::kCacheTotal"
        kNumUsageTypes "rocksdb::MemoryUtil::UsageType::kNumUsageTypes"

    cdef cppclass MemoryUtil:
        @staticmethod
        Status GetApproximateMemoryUsageByType(
          vector[DB*] dbs,
          unordered_set[const Cache*] cache_set,
          cpp_map[MemoryUtil_UsageType, uint64_t]* usage_by_type)
