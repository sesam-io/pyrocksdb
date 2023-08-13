import cython
from cpython cimport PyLong_AsVoidPtr
from libcpp.string cimport string
from libcpp.deque cimport deque
from libcpp.vector cimport vector
from libcpp cimport bool as cpp_bool

from libcpp.map cimport map as cpp_map
from libcpp.unordered_set cimport unordered_set
from cpython cimport bool as py_bool
from libcpp cimport bool as cpp_bool
from libc.stdint cimport uint32_t
from libc.stdint cimport uint64_t
from cython.operator cimport dereference as deref
from cpython.bytes cimport PyBytes_AsString
from cpython.bytes cimport PyBytes_Size
from cpython.bytes cimport PyBytes_FromString
from cpython.bytes cimport PyBytes_FromStringAndSize
from cpython.unicode cimport PyUnicode_Decode

from std_memory cimport shared_ptr
cimport options
cimport merge_operator
cimport filter_policy
cimport comparator
cimport slice_transform
cimport cache
cimport logger
cimport snapshot
cimport db
from db cimport DB as db_DB

cimport iterator
cimport backup
cimport checkpoint
cimport env
cimport table_factory
cimport memtablerep
cimport universal_compaction
cimport memory_util

# Enums are the only exception for direct imports
# Their name als already unique enough
from universal_compaction cimport kCompactionStopStyleSimilarSize
from universal_compaction cimport kCompactionStopStyleTotalSize

from options cimport kCompactionStyleLevel
from options cimport kCompactionStyleUniversal

from slice_ cimport Slice
from status cimport Status

import sys
from interfaces import MergeOperator as IMergeOperator
from interfaces import AssociativeMergeOperator as IAssociativeMergeOperator
from interfaces import FilterPolicy as IFilterPolicy
from interfaces import Comparator as IComparator
from interfaces import SliceTransform as ISliceTransform
import traceback
import errors
import struct

ctypedef const filter_policy.FilterPolicy ConstFilterPolicy

cdef extern from "cpp/utils.hpp" namespace "py_rocks":
    cdef const Slice* vector_data(vector[Slice]&)

# Prepare python for threaded usage.
# Python callbacks (merge, comparator)
# could be executed in a rocksdb background thread (eg. compaction).
cdef extern from "Python.h":
    void PyEval_InitThreads()
    object PyLong_FromVoidPtr(void*)

PyEval_InitThreads()

## Here comes the stuff to wrap the status to exception
cdef check_status(const Status& st):
    if st.ok():
        return

    if st.IsNotFound():
        raise errors.NotFound(st.ToString())

    if st.IsCorruption():
        raise errors.Corruption(st.ToString())

    if st.IsNotSupported():
        raise errors.NotSupported(st.ToString())

    if st.IsInvalidArgument():
        raise errors.InvalidArgument(st.ToString())

    if st.IsIOError():
        raise errors.RocksIOError(st.ToString())

    if st.IsMergeInProgress():
        raise errors.MergeInProgress(st.ToString())

    if st.IsIncomplete():
        raise errors.Incomplete(st.ToString())

    raise Exception("Unknown error: %s" % st.ToString())
######################################################


cdef string bytes_to_string(path) except *:
    return string(PyBytes_AsString(path), PyBytes_Size(path))

cdef string_to_bytes(string ob):
    return PyBytes_FromStringAndSize(ob.c_str(), ob.size())

cdef Slice bytes_to_slice(ob) except *:
    return Slice(PyBytes_AsString(ob), PyBytes_Size(ob))

cdef slice_to_bytes(Slice sl):
    return PyBytes_FromStringAndSize(sl.data(), sl.size())

## only for filsystem paths
cdef string path_to_string(object path) except *:
    if isinstance(path, bytes):
        return bytes_to_string(path)
    if isinstance(path, unicode):
        path = path.encode(sys.getfilesystemencoding())
        return bytes_to_string(path)
    else:
       raise TypeError("Wrong type for path: %s" % path)

cdef object string_to_path(string path):
    fs_encoding = sys.getfilesystemencoding().encode('ascii')
    return PyUnicode_Decode(path.c_str(), path.size(), fs_encoding, "replace")

## Here comes the stuff for the comparator
@cython.internal
cdef class PyComparator(object):
    cdef object get_ob(self):
        return None

    cdef const comparator.Comparator* get_comparator(self):
        return NULL

    cdef set_info_log(self, shared_ptr[logger.Logger] info_log):
        pass

@cython.internal
cdef class PyGenericComparator(PyComparator):
    cdef comparator.ComparatorWrapper* comparator_ptr
    cdef object ob

    def __cinit__(self, object ob):
        self.comparator_ptr = NULL
        if not isinstance(ob, IComparator):
            raise TypeError("%s is not of type %s" % (ob, IComparator))

        self.ob = ob
        self.comparator_ptr = new comparator.ComparatorWrapper(
                bytes_to_string(ob.name()),
                <void*>ob,
                compare_callback)

    def __dealloc__(self):
        if not self.comparator_ptr == NULL:
            del self.comparator_ptr

    cdef object get_ob(self):
        return self.ob

    cdef const comparator.Comparator* get_comparator(self):
        return <comparator.Comparator*> self.comparator_ptr

    cdef set_info_log(self, shared_ptr[logger.Logger] info_log):
        self.comparator_ptr.set_info_log(info_log)

@cython.internal
cdef class PyBytewiseComparator(PyComparator):
    cdef const comparator.Comparator* comparator_ptr

    def __cinit__(self):
        self.comparator_ptr = comparator.BytewiseComparator()

    def name(self):
        return PyBytes_FromString(self.comparator_ptr.Name())

    def compare(self, a, b):
        return self.comparator_ptr.Compare(
            bytes_to_slice(a),
            bytes_to_slice(b))

    cdef object get_ob(self):
       return self

    cdef const comparator.Comparator* get_comparator(self):
        return self.comparator_ptr

cdef int compare_callback(
    void* ctx,
    logger.Logger* log,
    string& error_msg,
    const Slice& a,
    const Slice& b) with gil:

    try:
        return (<object>ctx).compare(slice_to_bytes(a), slice_to_bytes(b))
    except BaseException as error:
        tb = traceback.format_exc()
        logger.Log(log, "Error in compare callback: %s", <bytes>tb)
        error_msg.assign(<bytes>str(error))

BytewiseComparator = PyBytewiseComparator
#########################################



## Here comes the stuff for the filter policy
@cython.internal
cdef class PyFilterPolicy(object):
    cdef object get_ob(self):
        return None

    cdef shared_ptr[ConstFilterPolicy] get_policy(self):
        return shared_ptr[ConstFilterPolicy]()

    cdef set_info_log(self, shared_ptr[logger.Logger] info_log):
        pass

#@cython.internal
#cdef class PyGenericFilterPolicy(PyFilterPolicy):
#    cdef shared_ptr[filter_policy.FilterPolicyWrapper] policy
#    cdef object ob
#
#    def __cinit__(self, object ob):
#        if not isinstance(ob, IFilterPolicy):
#            raise TypeError("%s is not of type %s" % (ob, IFilterPolicy))
#
#        self.ob = ob
#        self.policy.reset(new filter_policy.FilterPolicyWrapper(
#                bytes_to_string(ob.name()),
#                <void*>ob,
#                create_filter_callback,
#                key_may_match_callback))
#
#    cdef object get_ob(self):
#        return self.ob
#
#    cdef shared_ptr[ConstFilterPolicy] get_policy(self):
#        return <shared_ptr[ConstFilterPolicy]>(self.policy)
#
#    cdef set_info_log(self, shared_ptr[logger.Logger] info_log):
#        self.policy.get().set_info_log(info_log)


#cdef void create_filter_callback(
#    void* ctx,
#    logger.Logger* log,
#    string& error_msg,
#    const Slice* keys,
#    int n,
#    string* dst) with gil:
#
#    try:
#        ret = (<object>ctx).create_filter(
#            [slice_to_bytes(keys[i]) for i in range(n)])
#        dst.append(bytes_to_string(ret))
#    except BaseException as error:
#        tb = traceback.format_exc()
#        logger.Log(log, "Error in create filter callback: %s", <bytes>tb)
#        error_msg.assign(<bytes>str(error))

#cdef cpp_bool key_may_match_callback(
#    void* ctx,
#    logger.Logger* log,
#    string& error_msg,
#    const Slice& key,
#    const Slice& filt) with gil:
#
#    try:
#        return (<object>ctx).key_may_match(
#            slice_to_bytes(key),
#            slice_to_bytes(filt))
#    except BaseException as error:
#        tb = traceback.format_exc()
#        logger.Log(log, "Error in key_mach_match callback: %s", <bytes>tb)
#        error_msg.assign(<bytes>str(error))

@cython.internal
cdef class PyBloomFilterPolicy(PyFilterPolicy):
    cdef shared_ptr[ConstFilterPolicy] policy

    def __cinit__(self, int bits_per_key):
        self.policy.reset(filter_policy.NewBloomFilterPolicy(bits_per_key))

    def name(self):
        return PyBytes_FromString(self.policy.get().Name())

#    def create_filter(self, keys):
#        cdef string dst
#        cdef vector[Slice] c_keys
#
#        for key in keys:
#            c_keys.push_back(bytes_to_slice(key))
#
#        self.policy.get().CreateFilter(
#            vector_data(c_keys),
#            c_keys.size(),
#            cython.address(dst))
#
#        return string_to_bytes(dst)

#    def key_may_match(self, key, filter_):
#        return self.policy.get().KeyMayMatch(
#            bytes_to_slice(key),
#            bytes_to_slice(filter_))

    cdef object get_ob(self):
        return self

    cdef shared_ptr[ConstFilterPolicy] get_policy(self):
        return self.policy

BloomFilterPolicy = PyBloomFilterPolicy
#############################################



## Here comes the stuff for the merge operator
@cython.internal
cdef class PyMergeOperator(object):
    cdef shared_ptr[merge_operator.MergeOperator] merge_op
    cdef object ob

    def __cinit__(self, object ob):
        if isinstance(ob, IAssociativeMergeOperator):
            self.ob = ob
            self.merge_op.reset(
                <merge_operator.MergeOperator*>
                    new merge_operator.AssociativeMergeOperatorWrapper(
                        bytes_to_string(ob.name()),
                        <void*>(ob),
                        merge_callback))

        elif isinstance(ob, IMergeOperator):
            self.ob = ob
            self.merge_op.reset(
                <merge_operator.MergeOperator*>
                    new merge_operator.MergeOperatorWrapper(
                        bytes_to_string(ob.name()),
                        <void*>ob,
                        <void*>ob,
                        full_merge_callback,
                        partial_merge_callback))
        else:
            msg = "%s is not of this types %s"
            msg %= (ob, (IAssociativeMergeOperator, IMergeOperator))
            raise TypeError(msg)

    cdef object get_ob(self):
        return self.ob

    cdef shared_ptr[merge_operator.MergeOperator] get_operator(self):
        return self.merge_op

cdef cpp_bool merge_callback(
    void* ctx,
    const Slice& key,
    const Slice* existing_value,
    const Slice& value,
    string* new_value,
    logger.Logger* log) with gil:

    if existing_value == NULL:
        py_existing_value = None
    else:
        py_existing_value = slice_to_bytes(deref(existing_value))

    try:
        ret = (<object>ctx).merge(
            slice_to_bytes(key),
            py_existing_value,
            slice_to_bytes(value))

        if ret[0]:
            new_value.assign(bytes_to_string(ret[1]))
            return True
        return False

    except:
        tb = traceback.format_exc()
        logger.Log(log, "Error in merge_callback: %s", <bytes>tb)
        return False

cdef cpp_bool full_merge_callback(
    void* ctx,
    const Slice& key,
    const Slice* existing_value,
    const deque[string]& op_list,
    string* new_value,
    logger.Logger* log) with gil:

    if existing_value == NULL:
        py_existing_value = None
    else:
        py_existing_value = slice_to_bytes(deref(existing_value))

    try:
        ret = (<object>ctx).full_merge(
            slice_to_bytes(key),
            py_existing_value,
            [string_to_bytes(op_list[i]) for i in range(op_list.size())])

        if ret[0]:
            new_value.assign(bytes_to_string(ret[1]))
            return True
        return False

    except:
        tb = traceback.format_exc()
        logger.Log(log, "Error in full_merge_callback: %s", <bytes>tb)
        return False

cdef cpp_bool partial_merge_callback(
    void* ctx,
    const Slice& key,
    const Slice& left_op,
    const Slice& right_op,
    string* new_value,
    logger.Logger* log) with gil:

    try:
        ret = (<object>ctx).partial_merge(
            slice_to_bytes(key),
            slice_to_bytes(left_op),
            slice_to_bytes(right_op))

        if ret[0]:
            new_value.assign(bytes_to_string(ret[1]))
            return True
        return False

    except:
        tb = traceback.format_exc()
        logger.Log(log, "Error in partial_merge_callback: %s", <bytes>tb)
        return False
##############################################

#### Here comes the Cache stuff
@cython.internal
cdef class PyCache(object):
    cdef shared_ptr[cache.Cache] get_cache(self):
        return shared_ptr[cache.Cache]()

@cython.internal
cdef class PyLRUCache(PyCache):
    cdef shared_ptr[cache.Cache] cache_ob

    def __cinit__(self, capacity, shard_bits=None):
        if shard_bits is not None:
            self.cache_ob = cache.NewLRUCache(capacity, shard_bits)
        else:
            self.cache_ob = cache.NewLRUCache(capacity)

    cdef shared_ptr[cache.Cache] get_cache(self):
        return self.cache_ob

LRUCache = PyLRUCache
###############################

### Here comes the stuff for SliceTransform
@cython.internal
cdef class PySliceTransform(object):
    cdef shared_ptr[slice_transform.SliceTransform] transfomer
    cdef object ob

    def __cinit__(self, object ob):
        if not isinstance(ob, ISliceTransform):
            raise TypeError("%s is not of type %s" % (ob, ISliceTransform))

        self.ob = ob
        self.transfomer.reset(
            <slice_transform.SliceTransform*>
                new slice_transform.SliceTransformWrapper(
                    bytes_to_string(ob.name()),
                    <void*>ob,
                    slice_transform_callback,
                    slice_in_domain_callback,
                    slice_in_range_callback))

    cdef object get_ob(self):
        return self.ob

    cdef shared_ptr[slice_transform.SliceTransform] get_transformer(self):
        return self.transfomer

    cdef set_info_log(self, shared_ptr[logger.Logger] info_log):
        cdef slice_transform.SliceTransformWrapper* ptr
        ptr = <slice_transform.SliceTransformWrapper*> self.transfomer.get()
        ptr.set_info_log(info_log)


cdef Slice slice_transform_callback(
    void* ctx,
    logger.Logger* log,
    string& error_msg,
    const Slice& src) with gil:

    cdef size_t offset
    cdef size_t size

    try:
        ret = (<object>ctx).transform(slice_to_bytes(src))
        offset = ret[0]
        size = ret[1]
        if (offset + size) > src.size():
            msg = "offset(%i) + size(%i) is bigger than slice(%i)"
            raise Exception(msg  % (offset, size, src.size()))

        return Slice(src.data() + offset, size)
    except BaseException as error:
        tb = traceback.format_exc()
        logger.Log(log, "Error in slice transfrom callback: %s", <bytes>tb)
        error_msg.assign(<bytes>str(error))

cdef cpp_bool slice_in_domain_callback(
    void* ctx,
    logger.Logger* log,
    string& error_msg,
    const Slice& src) with gil:

    try:
        return (<object>ctx).in_domain(slice_to_bytes(src))
    except BaseException as error:
        tb = traceback.format_exc()
        logger.Log(log, "Error in slice transfrom callback: %s", <bytes>tb)
        error_msg.assign(<bytes>str(error))

cdef cpp_bool slice_in_range_callback(
    void* ctx,
    logger.Logger* log,
    string& error_msg,
    const Slice& src) with gil:

    try:
        return (<object>ctx).in_range(slice_to_bytes(src))
    except BaseException as error:
        tb = traceback.format_exc()
        logger.Log(log, "Error in slice transfrom callback: %s", <bytes>tb)
        error_msg.assign(<bytes>str(error))
###########################################

## Here are the TableFactories
@cython.internal
cdef class PyTableFactory(object):
    cdef shared_ptr[table_factory.TableFactory] factory

    cdef shared_ptr[table_factory.TableFactory] get_table_factory(self):
        return self.factory

    cdef set_info_log(self, shared_ptr[logger.Logger] info_log):
        pass

cdef class BlockBasedTableFactory(PyTableFactory):
    cdef PyFilterPolicy py_filter_policy

    def __init__(self,
            index_type='binary_search',
            checksum='crc32',
            PyCache block_cache=None,
            PyCache block_cache_compressed=None,
            filter_policy=None,
            no_block_cache=False,
            block_size=None,
            block_size_deviation=None,
            block_restart_interval=None,
            whole_key_filtering=None,
            cache_index_and_filter_blocks=None,
            format_version=None,
            partition_filters=None,
            metadata_block_size=None,
            pin_top_level_index_and_filter=None,
            cache_index_and_filter_blocks_with_high_priority=None,
            pin_l0_filter_and_index_blocks_in_cache=None
            ):

        cdef table_factory.BlockBasedTableOptions table_options

        if index_type == 'binary_search':
            table_options.index_type = table_factory.kBinarySearch
        elif index_type == 'hash_search':
            table_options.index_type = table_factory.kHashSearch
        elif index_type == 'two_level_index_search':
            table_options.index_type = table_factory.kTwoLevelIndexSearch
        else:
            raise ValueError("Unknown index_type: %s" % index_type)

        if checksum == 'crc32':
            table_options.checksum = table_factory.kCRC32c
        elif checksum == 'xxhash':
            table_options.checksum = table_factory.kxxHash
        else:
            raise ValueError("Unknown checksum: %s" % checksum)

        if no_block_cache:
            table_options.no_block_cache = True
        else:
            table_options.no_block_cache = False

        # If the following options are None use the rocksdb default.
        if block_size is not None:
            table_options.block_size = block_size

        if block_size_deviation is not None:
            table_options.block_size_deviation = block_size_deviation

        if block_restart_interval is not None:
            table_options.block_restart_interval = block_restart_interval

        if whole_key_filtering is not None:
            if whole_key_filtering:
                table_options.whole_key_filtering = True
            else:
                table_options.whole_key_filtering = False

        if block_cache is not None:
            table_options.block_cache = block_cache.get_cache()

        if block_cache_compressed is not None:
            table_options.block_cache_compressed = block_cache_compressed.get_cache()

        # Set the filter_policy
        self.py_filter_policy = None
        if filter_policy is not None:
            if isinstance(filter_policy, PyFilterPolicy):
                if (<PyFilterPolicy?>filter_policy).get_policy().get() == NULL:
                    raise Exception("Cannot set filter policy: %s" % filter_policy)
                self.py_filter_policy = filter_policy
            else:
                raise AssertionError(f"Got an unsupported filter_policy type: {type(filter_policy)}.")
                #self.py_filter_policy = PyGenericFilterPolicy(filter_policy)

            table_options.filter_policy = self.py_filter_policy.get_policy()

        if cache_index_and_filter_blocks is not None:
            table_options.cache_index_and_filter_blocks = cache_index_and_filter_blocks

        if format_version is not None:
            table_options.format_version = format_version

        if partition_filters is not None:
            table_options.partition_filters = partition_filters

        if metadata_block_size is not None:
            table_options.metadata_block_size = metadata_block_size

        if pin_top_level_index_and_filter is not None:
            table_options.pin_top_level_index_and_filter = pin_top_level_index_and_filter

        if cache_index_and_filter_blocks_with_high_priority is not None:
            table_options.cache_index_and_filter_blocks_with_high_priority = cache_index_and_filter_blocks_with_high_priority

        if pin_l0_filter_and_index_blocks_in_cache is not None:
            table_options.pin_l0_filter_and_index_blocks_in_cache = pin_l0_filter_and_index_blocks_in_cache

        self.factory.reset(table_factory.NewBlockBasedTableFactory(table_options))

    cdef set_info_log(self, shared_ptr[logger.Logger] info_log):
        if self.py_filter_policy is not None:
            self.py_filter_policy.set_info_log(info_log)

cdef class PlainTableFactory(PyTableFactory):
    def __init__(
            self,
            user_key_len=0,
            bloom_bits_per_key=10,
            hash_table_ratio=0.75,
            index_sparseness=10,
            huge_page_tlb_size=0,
            encoding_type='plain',
            py_bool full_scan_mode=False,
            py_bool store_index_in_file=False):

        cdef table_factory.PlainTableOptions table_options

        table_options.user_key_len = user_key_len
        table_options.bloom_bits_per_key = bloom_bits_per_key
        table_options.hash_table_ratio = hash_table_ratio
        table_options.index_sparseness = index_sparseness
        table_options.huge_page_tlb_size = huge_page_tlb_size

        if encoding_type == 'plain':
            table_options.encoding_type = table_factory.kPlain
        elif encoding_type == 'prefix':
            table_options.encoding_type = table_factory.kPrefix
        else:
            raise ValueError("Unknown encoding_type: %s" % encoding_type)

        table_options.full_scan_mode = full_scan_mode
        table_options.store_index_in_file = store_index_in_file

        self.factory.reset( table_factory.NewPlainTableFactory(table_options))
#############################################

### Here are the MemtableFactories
@cython.internal
cdef class PyMemtableFactory(object):
    cdef shared_ptr[memtablerep.MemTableRepFactory] factory

    cdef shared_ptr[memtablerep.MemTableRepFactory] get_memtable_factory(self):
        return self.factory

cdef class SkipListMemtableFactory(PyMemtableFactory):
    def __init__(self):
        self.factory.reset(memtablerep.NewSkipListFactory())

cdef class VectorMemtableFactory(PyMemtableFactory):
    def __init__(self, count=0):
        self.factory.reset(memtablerep.NewVectorRepFactory(count))

cdef class HashSkipListMemtableFactory(PyMemtableFactory):
    def __init__(
            self,
            bucket_count=1000000,
            skiplist_height=4,
            skiplist_branching_factor=4):

        self.factory.reset(
            memtablerep.NewHashSkipListRepFactory(
                bucket_count,
                skiplist_height,
                skiplist_branching_factor))

cdef class HashLinkListMemtableFactory(PyMemtableFactory):
    def __init__(self, bucket_count=50000):
        self.factory.reset(memtablerep.NewHashLinkListRepFactory(bucket_count))
##################################

cdef class CompressionType(object):
    no_compression = u'no_compression'
    snappy_compression = u'snappy_compression'
    zlib_compression = u'zlib_compression'
    bzip2_compression = u'bzip2_compression'
    lz4_compression = u'lz4_compression'
    lz4hc_compression = u'lz4hc_compression'


cdef class ColumnFamilyHandle(object):
    cdef db.ColumnFamilyHandle* handle
    cdef uint32_t shared_column_family_prefix
    cdef cpp_bool _has_been_closed
    cdef bytes shared_column_family_prefix_bytes
    cdef Slice shared_column_family_prefix_slice
    cdef bytes shared_column_family_prefix_iterate_upper_bound_bytes
    cdef Slice shared_column_family_prefix_iterate_upper_bound_slice

    def __init__(self, shared_column_family_prefix=0, shared_column_family_handle_pointer=0):
        """
        :param shared_column_family_prefix:
            If this object represents a normal columnfamily this value is 0.
            If this is > 0 it means that this object represents a set of prefixed items in a shared columnfamily.
        """
        self._has_been_closed = False
        self.shared_column_family_prefix = shared_column_family_prefix
        if shared_column_family_prefix > 0:
            if type(shared_column_family_prefix) is not int:
                raise TypeError(f"Invalid shared_column_family_prefix type: {type(shared_column_family_prefix)}")
            if shared_column_family_prefix > (2**32 - 2): # we subract 2 instead of one since we need to make sure the shared_column_family_prefix_iterate_upper_bound can be larger than shared_column_family_prefix
                raise TypeError(f"The shared_column_family_prefix value is too large and won't fit in an uint32: {shared_column_family_prefix}")

            if type(shared_column_family_handle_pointer) is not int:
                raise TypeError(f"Invalid shared_column_family_handle_pointer type: {type(shared_column_family_handle_pointer)}")
            self.handle = <db.ColumnFamilyHandle*>PyLong_AsVoidPtr(shared_column_family_handle_pointer)

            self.shared_column_family_prefix_bytes = struct.pack("<I", shared_column_family_prefix)
            self.shared_column_family_prefix_iterate_upper_bound_bytes = struct.pack("<I", shared_column_family_prefix + 1)
            self.shared_column_family_prefix_slice = bytes_to_slice(self.shared_column_family_prefix_bytes)
            self.shared_column_family_prefix_iterate_upper_bound_slice = bytes_to_slice(self.shared_column_family_prefix_iterate_upper_bound_bytes)

    property name:
        def __get__(self):
            if self._has_been_closed:
                raise AssertionError("This ColumnFamilyHandle has been closed and should not have been used!")
            return self.handle.GetName()

    property id:
        def __get__(self):
            if self._has_been_closed:
                raise AssertionError("This ColumnFamilyHandle has been closed and should not have been used!")
            return self.handle.GetID()

    property shared_column_family_prefix:
        def __get__(self):
            if self._has_been_closed:
                raise AssertionError("This ColumnFamilyHandle has been closed and should not have been used!")
            return self.shared_column_family_prefix

    def get_pointer(self):
        if self._has_been_closed:
            raise AssertionError("This ColumnFamilyHandle has been closed and should not have been used!")
        return PyLong_FromVoidPtr(self.handle)

    def close(self):
        if self._has_been_closed:
            raise AssertionError("This ColumnFamilyHandle has already been closed!")
        self._has_been_closed = True
        self.handle = NULL


cdef class ColumnFamilyOptions(object):
    cdef options.ColumnFamilyOptions* opts
    cdef PyComparator py_comparator
    cdef PyMergeOperator py_merge_operator
    cdef PySliceTransform py_prefix_extractor
    cdef PyTableFactory py_table_factory
    cdef PyMemtableFactory py_memtable_factory
    cdef PyCache py_row_cache

    def __cinit__(self):
        self.opts = NULL
        self.opts = new options.ColumnFamilyOptions()

    def __dealloc__(self):
        if not self.opts == NULL:
            del self.opts

    def __init__(self, **kwargs):
        self.py_comparator = BytewiseComparator()
        self.py_merge_operator = None
        self.py_prefix_extractor = None
        self.py_table_factory = None
        self.py_memtable_factory = None
        self.py_row_cache = None

        for key, value in kwargs.items():
            setattr(self, key, value)

    property write_buffer_size:
        def __get__(self):
            return self.opts.write_buffer_size
        def __set__(self, value):
            self.opts.write_buffer_size = value

    property max_write_buffer_number:
        def __get__(self):
            return self.opts.max_write_buffer_number
        def __set__(self, value):
            self.opts.max_write_buffer_number = value

    property min_write_buffer_number_to_merge:
        def __get__(self):
            return self.opts.min_write_buffer_number_to_merge
        def __set__(self, value):
            self.opts.min_write_buffer_number_to_merge = value

    property compression:
        def __get__(self):
            return get_py_compression_type(self.opts.compression)

        def __set__(self, value):
            self.opts.compression = get_cpp_comperssion_type(value)

    property num_levels:
        def __get__(self):
            return self.opts.num_levels
        def __set__(self, value):
            self.opts.num_levels = value

    property level0_file_num_compaction_trigger:
        def __get__(self):
            return self.opts.level0_file_num_compaction_trigger
        def __set__(self, value):
            self.opts.level0_file_num_compaction_trigger = value

    property level0_slowdown_writes_trigger:
        def __get__(self):
            return self.opts.level0_slowdown_writes_trigger
        def __set__(self, value):
            self.opts.level0_slowdown_writes_trigger = value

    property level0_stop_writes_trigger:
        def __get__(self):
            return self.opts.level0_stop_writes_trigger
        def __set__(self, value):
            self.opts.level0_stop_writes_trigger = value

    property target_file_size_base:
        def __get__(self):
            return self.opts.target_file_size_base
        def __set__(self, value):
            self.opts.target_file_size_base = value

    property target_file_size_multiplier:
        def __get__(self):
            return self.opts.target_file_size_multiplier
        def __set__(self, value):
            self.opts.target_file_size_multiplier = value

    property max_bytes_for_level_base:
        def __get__(self):
            return self.opts.max_bytes_for_level_base
        def __set__(self, value):
            self.opts.max_bytes_for_level_base = value

    property max_bytes_for_level_multiplier:
        def __get__(self):
            return self.opts.max_bytes_for_level_multiplier
        def __set__(self, value):
            self.opts.max_bytes_for_level_multiplier = value

    property max_bytes_for_level_multiplier_additional:
        def __get__(self):
            return self.opts.max_bytes_for_level_multiplier_additional
        def __set__(self, value):
            self.opts.max_bytes_for_level_multiplier_additional = value

    property arena_block_size:
        def __get__(self):
            return self.opts.arena_block_size
        def __set__(self, value):
            self.opts.arena_block_size = value

    property disable_auto_compactions:
        def __get__(self):
            return self.opts.disable_auto_compactions
        def __set__(self, value):
            self.opts.disable_auto_compactions = value

    property compaction_style:
        def __get__(self):
            if self.opts.compaction_style == kCompactionStyleLevel:
                return 'level'
            if self.opts.compaction_style == kCompactionStyleUniversal:
                return 'universal'
            raise Exception("Unknown compaction_style")

        def __set__(self, str value):
            if value == 'level':
                self.opts.compaction_style = kCompactionStyleLevel
            elif value == 'universal':
                self.opts.compaction_style = kCompactionStyleUniversal
            else:
                raise Exception("Unknown compaction style")

    property compaction_options_universal:
        def __get__(self):
            cdef universal_compaction.CompactionOptionsUniversal uopts
            cdef dict ret_ob = {}

            uopts = self.opts.compaction_options_universal

            ret_ob['size_ratio'] = uopts.size_ratio
            ret_ob['min_merge_width'] = uopts.min_merge_width
            ret_ob['max_merge_width'] = uopts.max_merge_width
            ret_ob['max_size_amplification_percent'] = uopts.max_size_amplification_percent
            ret_ob['compression_size_percent'] = uopts.compression_size_percent

            if uopts.stop_style == kCompactionStopStyleSimilarSize:
                ret_ob['stop_style'] = 'similar_size'
            elif uopts.stop_style == kCompactionStopStyleTotalSize:
                ret_ob['stop_style'] = 'total_size'
            else:
                raise Exception("Unknown compaction style")

            return ret_ob

        def __set__(self, dict value):
            cdef universal_compaction.CompactionOptionsUniversal* uopts
            uopts = cython.address(self.opts.compaction_options_universal)

            if 'size_ratio' in value:
                uopts.size_ratio  = value['size_ratio']

            if 'min_merge_width' in value:
                uopts.min_merge_width = value['min_merge_width']

            if 'max_merge_width' in value:
                uopts.max_merge_width = value['max_merge_width']

            if 'max_size_amplification_percent' in value:
                uopts.max_size_amplification_percent = value['max_size_amplification_percent']

            if 'compression_size_percent' in value:
                uopts.compression_size_percent = value['compression_size_percent']

            if 'stop_style' in value:
                if value['stop_style'] == 'similar_size':
                    uopts.stop_style = kCompactionStopStyleSimilarSize
                elif value['stop_style'] == 'total_size':
                    uopts.stop_style = kCompactionStopStyleTotalSize
                else:
                    raise Exception("Unknown compaction style")

    property max_sequential_skip_in_iterations:
        def __get__(self):
            return self.opts.max_sequential_skip_in_iterations
        def __set__(self, value):
            self.opts.max_sequential_skip_in_iterations = value

    property inplace_update_support:
        def __get__(self):
            return self.opts.inplace_update_support
        def __set__(self, value):
            self.opts.inplace_update_support = value

    property table_factory:
        def __get__(self):
            return self.py_table_factory

        def __set__(self, PyTableFactory value):
            self.py_table_factory = value
            self.opts.table_factory = value.get_table_factory()

    property memtable_factory:
        def __get__(self):
            return self.py_memtable_factory

        def __set__(self, PyMemtableFactory value):
            self.py_memtable_factory = value
            self.opts.memtable_factory = value.get_memtable_factory()

    property inplace_update_num_locks:
        def __get__(self):
            return self.opts.inplace_update_num_locks
        def __set__(self, value):
            self.opts.inplace_update_num_locks = value

    property comparator:
        def __get__(self):
            return self.py_comparator.get_ob()

        def __set__(self, value):
            if isinstance(value, PyComparator):
                if (<PyComparator?>value).get_comparator() == NULL:
                    raise Exception("Cannot set %s as comparator" % value)
                else:
                    self.py_comparator = value
            else:
                self.py_comparator = PyGenericComparator(value)

            self.opts.comparator = self.py_comparator.get_comparator()

    property merge_operator:
        def __get__(self):
            if self.py_merge_operator is None:
                return None
            return self.py_merge_operator.get_ob()

        def __set__(self, value):
            self.py_merge_operator = PyMergeOperator(value)
            self.opts.merge_operator = self.py_merge_operator.get_operator()

    property prefix_extractor:
        def __get__(self):
            if self.py_prefix_extractor is None:
                return None
            return self.py_prefix_extractor.get_ob()

        def __set__(self, value):
            self.py_prefix_extractor = PySliceTransform(value)
            self.opts.prefix_extractor = self.py_prefix_extractor.get_transformer()

#     property row_cache:
#         def __get__(self):
#             return self.py_row_cache
#
#         def __set__(self, value):
#             if value is None:
#                 self.py_row_cache = None
#                 self.opts.row_cache.reset()
#             elif not isinstance(value, PyCache):
#                 raise Exception("row_cache must be a Cache object")
#             else:
#                 self.py_row_cache = value
#                 self.opts.row_cache = self.py_row_cache.get_cache()

    property enable_blob_files:
        def __get__(self):
            return self.opts.enable_blob_files
        def __set__(self, value):
            self.opts.enable_blob_files = value

    property min_blob_size:
        def __get__(self):
            return self.opts.min_blob_size
        def __set__(self, value):
            self.opts.min_blob_size = value

    property blob_file_size:
        def __get__(self):
            return self.opts.blob_file_size
        def __set__(self, value):
            self.opts.blob_file_size = value

    property blob_compression_type:
        def __get__(self):
            return get_py_compression_type(self.opts.blob_compression_type)

        def __set__(self, value):
            self.opts.blob_compression_type = get_cpp_comperssion_type(value)

    property enable_blob_garbage_collection:
        def __get__(self):
            return self.opts.enable_blob_garbage_collection
        def __set__(self, value):
            self.opts.enable_blob_garbage_collection = value

    property blob_garbage_collection_age_cutoff:
        def __get__(self):
            return self.opts.blob_garbage_collection_age_cutoff
        def __set__(self, value):
            self.opts.blob_garbage_collection_age_cutoff = value


cdef class Env_Priority(object):
    BOTTOM = "BOTTOM"
    LOW = "LOW"
    HIGH = "HIGH"
    USER = "USER"
    TOTAL = "TOTAL"

cdef class Env:
    cdef env.Env* c_env

    def __cinit__(self):
        self.c_env = NULL

    def __dealloc__(self):
        self.c_env = NULL

    @staticmethod
    def Default():
        # Call to __new__ bypasses __init__ constructor
        cdef Env py_env = Env.__new__(Env)
        py_env.c_env = env.Env_Default()
        return py_env

    def SetBackgroundThreads(self, number: int, priority):
        cdef env.Env_Priority c_priority
        assert self.c_env != NULL
        if priority == Env_Priority.BOTTOM:
            c_priority = env.Env_Priority.BOTTOM
        elif priority == Env_Priority.LOW:
            c_priority = env.Env_Priority.LOW
        elif priority == Env_Priority.HIGH:
            c_priority = env.Env_Priority.HIGH
        elif priority == Env_Priority.USER:
            c_priority = env.Env_Priority.USER
        elif priority == Env_Priority.TOTAL:
            c_priority = env.Env_Priority.TOTAL
        else:
            raise AssertionError(f"Unknown priority '{priority}'!")
        self.c_env.SetBackgroundThreads(number, c_priority)


cdef class DBOptions(object):
    cdef options.DBOptions* opts
    cdef PyComparator py_comparator
    cdef PyMergeOperator py_merge_operator
    cdef PySliceTransform py_prefix_extractor
    cdef PyTableFactory py_table_factory
    cdef PyMemtableFactory py_memtable_factory
    cdef PyCache py_row_cache

    # Used to protect sharing of Options with many DB-objects
    cdef cpp_bool in_use

    def __cinit__(self):
        self.opts = NULL
        self.opts = new options.DBOptions()
        self.in_use = False

    def __dealloc__(self):
        if not self.opts == NULL:
            del self.opts

    def __init__(self, **kwargs):
        self.py_comparator = BytewiseComparator()
        self.py_merge_operator = None
        self.py_prefix_extractor = None
        self.py_table_factory = None
        self.py_memtable_factory = None
        self.py_row_cache = None

        for key, value in kwargs.items():
            setattr(self, key, value)

    def IncreaseParallelism(self, total_threads):
        self.opts.IncreaseParallelism(total_threads)

    property create_if_missing:
        def __get__(self):
            return self.opts.create_if_missing
        def __set__(self, value):
            self.opts.create_if_missing = value

    property error_if_exists:
        def __get__(self):
            return self.opts.error_if_exists
        def __set__(self, value):
            self.opts.error_if_exists = value

    property paranoid_checks:
        def __get__(self):
            return self.opts.paranoid_checks
        def __set__(self, value):
            self.opts.paranoid_checks = value

    property db_write_buffer_size:
        def __get__(self):
            return self.opts.db_write_buffer_size
        def __set__(self, value):
            self.opts.db_write_buffer_size = value

    property max_open_files:
        def __get__(self):
            return self.opts.max_open_files
        def __set__(self, value):
            self.opts.max_open_files = value

    property use_fsync:
        def __get__(self):
            return self.opts.use_fsync
        def __set__(self, value):
            self.opts.use_fsync = value

    property db_log_dir:
        def __get__(self):
            return string_to_path(self.opts.db_log_dir)
        def __set__(self, value):
            self.opts.db_log_dir = path_to_string(value)

    property wal_dir:
        def __get__(self):
            return string_to_path(self.opts.wal_dir)
        def __set__(self, value):
            self.opts.wal_dir = path_to_string(value)

    property delete_obsolete_files_period_micros:
        def __get__(self):
            return self.opts.delete_obsolete_files_period_micros
        def __set__(self, value):
            self.opts.delete_obsolete_files_period_micros = value

    property max_total_wal_size:
        def __get__(self):
            return self.opts.max_total_wal_size
        def __set__(self, value):
            self.opts.max_total_wal_size = value

    property max_background_jobs:
        def __get__(self):
            return self.opts.max_background_jobs
        def __set__(self, value):
            self.opts.max_background_jobs = value

    property max_subcompactions:
        def __get__(self):
            return self.opts.max_subcompactions
        def __set__(self, value):
            self.opts.max_subcompactions = value

    property max_log_file_size:
        def __get__(self):
            return self.opts.max_log_file_size
        def __set__(self, value):
            self.opts.max_log_file_size = value

    property log_file_time_to_roll:
        def __get__(self):
            return self.opts.log_file_time_to_roll
        def __set__(self, value):
            self.opts.log_file_time_to_roll = value

    property keep_log_file_num:
        def __get__(self):
            return self.opts.keep_log_file_num
        def __set__(self, value):
            self.opts.keep_log_file_num = value

    property max_manifest_file_size:
        def __get__(self):
            return self.opts.max_manifest_file_size
        def __set__(self, value):
            self.opts.max_manifest_file_size = value

    property table_cache_numshardbits:
        def __get__(self):
            return self.opts.table_cache_numshardbits
        def __set__(self, value):
            self.opts.table_cache_numshardbits = value

    property wal_ttl_seconds:
        def __get__(self):
            return self.opts.WAL_ttl_seconds
        def __set__(self, value):
            self.opts.WAL_ttl_seconds = value

    property wal_size_limit_mb:
        def __get__(self):
            return self.opts.WAL_size_limit_MB
        def __set__(self, value):
            self.opts.WAL_size_limit_MB = value

    property manifest_preallocation_size:
        def __get__(self):
            return self.opts.manifest_preallocation_size
        def __set__(self, value):
            self.opts.manifest_preallocation_size = value

    property allow_mmap_reads:
        def __get__(self):
            return self.opts.allow_mmap_reads
        def __set__(self, value):
            self.opts.allow_mmap_reads = value

    property allow_mmap_writes:
        def __get__(self):
            return self.opts.allow_mmap_writes
        def __set__(self, value):
            self.opts.allow_mmap_writes = value

    property is_fd_close_on_exec:
        def __get__(self):
            return self.opts.is_fd_close_on_exec
        def __set__(self, value):
            self.opts.is_fd_close_on_exec = value

    property stats_dump_period_sec:
        def __get__(self):
            return self.opts.stats_dump_period_sec
        def __set__(self, value):
            self.opts.stats_dump_period_sec = value

    property advise_random_on_open:
        def __get__(self):
            return self.opts.advise_random_on_open
        def __set__(self, value):
            self.opts.advise_random_on_open = value

    property use_adaptive_mutex:
        def __get__(self):
            return self.opts.use_adaptive_mutex
        def __set__(self, value):
            self.opts.use_adaptive_mutex = value

    property bytes_per_sync:
        def __get__(self):
            return self.opts.bytes_per_sync
        def __set__(self, value):
            self.opts.bytes_per_sync = value

    property row_cache:
        def __get__(self):
            return self.py_row_cache

        def __set__(self, value):
            if value is None:
                self.py_row_cache = None
                self.opts.row_cache.reset()
            elif not isinstance(value, PyCache):
                raise Exception("row_cache must be a Cache object")
            else:
                self.py_row_cache = value
                self.opts.row_cache = self.py_row_cache.get_cache()


def get_py_compression_type(value: options.CompressionType):
    if value == options.kNoCompression:
        return CompressionType.no_compression
    elif value  == options.kSnappyCompression:
        return CompressionType.snappy_compression
    elif value == options.kZlibCompression:
        return CompressionType.zlib_compression
    elif value == options.kBZip2Compression:
        return CompressionType.bzip2_compression
    elif value == options.kLZ4Compression:
        return CompressionType.lz4_compression
    elif value == options.kLZ4HCCompression:
        return CompressionType.lz4hc_compression
    else:
        raise Exception("Unknown type: %s" % value)

cdef options.CompressionType get_cpp_comperssion_type(value: str):
    if value == CompressionType.no_compression:
        return options.kNoCompression
    elif value == CompressionType.snappy_compression:
        return options.kSnappyCompression
    elif value == CompressionType.zlib_compression:
        return options.kZlibCompression
    elif value == CompressionType.bzip2_compression:
        return options.kBZip2Compression
    elif value == CompressionType.lz4_compression:
        return options.kLZ4Compression
    elif value == CompressionType.lz4hc_compression:
        return options.kLZ4HCCompression
    else:
        raise TypeError("Unknown compression: %s" % value)


# TODO: The c++ Options class inherits from both DBOptions and ColoumnFamilyOptions, so ideally the cython Options
# class should do the same instead of redeclaring everything.
cdef class Options(object):
    cdef options.Options* opts
    cdef PyComparator py_comparator
    cdef PyMergeOperator py_merge_operator
    cdef PySliceTransform py_prefix_extractor
    cdef PyTableFactory py_table_factory
    cdef PyMemtableFactory py_memtable_factory
    cdef PyCache py_row_cache

    # Used to protect sharing of Options with many DB-objects
    cdef cpp_bool in_use

    def __cinit__(self):
        self.opts = NULL
        self.opts = new options.Options()
        self.in_use = False

    def __dealloc__(self):
        if not self.opts == NULL:
            del self.opts

    def __init__(self, **kwargs):
        self.py_comparator = BytewiseComparator()
        self.py_merge_operator = None
        self.py_prefix_extractor = None
        self.py_table_factory = None
        self.py_memtable_factory = None
        self.py_row_cache = None

        for key, value in kwargs.items():
            setattr(self, key, value)

    def IncreaseParallelism(self, total_threads):
        self.opts.IncreaseParallelism(total_threads)

    property create_if_missing:
        def __get__(self):
            return self.opts.create_if_missing
        def __set__(self, value):
            self.opts.create_if_missing = value

    property error_if_exists:
        def __get__(self):
            return self.opts.error_if_exists
        def __set__(self, value):
            self.opts.error_if_exists = value

    property paranoid_checks:
        def __get__(self):
            return self.opts.paranoid_checks
        def __set__(self, value):
            self.opts.paranoid_checks = value

    property db_write_buffer_size:
        def __get__(self):
            return self.opts.db_write_buffer_size
        def __set__(self, value):
            self.opts.db_write_buffer_size = value

    property write_buffer_size:
        def __get__(self):
            return self.opts.write_buffer_size
        def __set__(self, value):
            self.opts.write_buffer_size = value

    property max_write_buffer_number:
        def __get__(self):
            return self.opts.max_write_buffer_number
        def __set__(self, value):
            self.opts.max_write_buffer_number = value

    property min_write_buffer_number_to_merge:
        def __get__(self):
            return self.opts.min_write_buffer_number_to_merge
        def __set__(self, value):
            self.opts.min_write_buffer_number_to_merge = value

    property max_open_files:
        def __get__(self):
            return self.opts.max_open_files
        def __set__(self, value):
            self.opts.max_open_files = value

    property compression:
        def __get__(self):
            return get_py_compression_type(self.opts.compression)

        def __set__(self, value):
            self.opts.compression = get_cpp_comperssion_type(value)

    property num_levels:
        def __get__(self):
            return self.opts.num_levels
        def __set__(self, value):
            self.opts.num_levels = value

    property level0_file_num_compaction_trigger:
        def __get__(self):
            return self.opts.level0_file_num_compaction_trigger
        def __set__(self, value):
            self.opts.level0_file_num_compaction_trigger = value

    property level0_slowdown_writes_trigger:
        def __get__(self):
            return self.opts.level0_slowdown_writes_trigger
        def __set__(self, value):
            self.opts.level0_slowdown_writes_trigger = value

    property level0_stop_writes_trigger:
        def __get__(self):
            return self.opts.level0_stop_writes_trigger
        def __set__(self, value):
            self.opts.level0_stop_writes_trigger = value

    property target_file_size_base:
        def __get__(self):
            return self.opts.target_file_size_base
        def __set__(self, value):
            self.opts.target_file_size_base = value

    property target_file_size_multiplier:
        def __get__(self):
            return self.opts.target_file_size_multiplier
        def __set__(self, value):
            self.opts.target_file_size_multiplier = value

    property max_bytes_for_level_base:
        def __get__(self):
            return self.opts.max_bytes_for_level_base
        def __set__(self, value):
            self.opts.max_bytes_for_level_base = value

    property max_bytes_for_level_multiplier:
        def __get__(self):
            return self.opts.max_bytes_for_level_multiplier
        def __set__(self, value):
            self.opts.max_bytes_for_level_multiplier = value

    property max_bytes_for_level_multiplier_additional:
        def __get__(self):
            return self.opts.max_bytes_for_level_multiplier_additional
        def __set__(self, value):
            self.opts.max_bytes_for_level_multiplier_additional = value

    property use_fsync:
        def __get__(self):
            return self.opts.use_fsync
        def __set__(self, value):
            self.opts.use_fsync = value

    property db_log_dir:
        def __get__(self):
            return string_to_path(self.opts.db_log_dir)
        def __set__(self, value):
            self.opts.db_log_dir = path_to_string(value)

    property wal_dir:
        def __get__(self):
            return string_to_path(self.opts.wal_dir)
        def __set__(self, value):
            self.opts.wal_dir = path_to_string(value)

    property delete_obsolete_files_period_micros:
        def __get__(self):
            return self.opts.delete_obsolete_files_period_micros
        def __set__(self, value):
            self.opts.delete_obsolete_files_period_micros = value

    property max_total_wal_size:
        def __get__(self):
            return self.opts.max_total_wal_size
        def __set__(self, value):
            self.opts.max_total_wal_size = value

    property max_background_jobs:
        def __get__(self):
            return self.opts.max_background_jobs
        def __set__(self, value):
            self.opts.max_background_jobs = value

    property max_subcompactions:
        def __get__(self):
            return self.opts.max_subcompactions
        def __set__(self, value):
            self.opts.max_subcompactions = value

    property max_log_file_size:
        def __get__(self):
            return self.opts.max_log_file_size
        def __set__(self, value):
            self.opts.max_log_file_size = value

    property log_file_time_to_roll:
        def __get__(self):
            return self.opts.log_file_time_to_roll
        def __set__(self, value):
            self.opts.log_file_time_to_roll = value

    property keep_log_file_num:
        def __get__(self):
            return self.opts.keep_log_file_num
        def __set__(self, value):
            self.opts.keep_log_file_num = value

    property max_manifest_file_size:
        def __get__(self):
            return self.opts.max_manifest_file_size
        def __set__(self, value):
            self.opts.max_manifest_file_size = value

    property table_cache_numshardbits:
        def __get__(self):
            return self.opts.table_cache_numshardbits
        def __set__(self, value):
            self.opts.table_cache_numshardbits = value

    property arena_block_size:
        def __get__(self):
            return self.opts.arena_block_size
        def __set__(self, value):
            self.opts.arena_block_size = value

    property disable_auto_compactions:
        def __get__(self):
            return self.opts.disable_auto_compactions
        def __set__(self, value):
            self.opts.disable_auto_compactions = value

    property wal_ttl_seconds:
        def __get__(self):
            return self.opts.WAL_ttl_seconds
        def __set__(self, value):
            self.opts.WAL_ttl_seconds = value

    property wal_size_limit_mb:
        def __get__(self):
            return self.opts.WAL_size_limit_MB
        def __set__(self, value):
            self.opts.WAL_size_limit_MB = value

    property manifest_preallocation_size:
        def __get__(self):
            return self.opts.manifest_preallocation_size
        def __set__(self, value):
            self.opts.manifest_preallocation_size = value

    property allow_mmap_reads:
        def __get__(self):
            return self.opts.allow_mmap_reads
        def __set__(self, value):
            self.opts.allow_mmap_reads = value

    property allow_mmap_writes:
        def __get__(self):
            return self.opts.allow_mmap_writes
        def __set__(self, value):
            self.opts.allow_mmap_writes = value

    property is_fd_close_on_exec:
        def __get__(self):
            return self.opts.is_fd_close_on_exec
        def __set__(self, value):
            self.opts.is_fd_close_on_exec = value

    property stats_dump_period_sec:
        def __get__(self):
            return self.opts.stats_dump_period_sec
        def __set__(self, value):
            self.opts.stats_dump_period_sec = value

    property advise_random_on_open:
        def __get__(self):
            return self.opts.advise_random_on_open
        def __set__(self, value):
            self.opts.advise_random_on_open = value

    property use_adaptive_mutex:
        def __get__(self):
            return self.opts.use_adaptive_mutex
        def __set__(self, value):
            self.opts.use_adaptive_mutex = value

    property bytes_per_sync:
        def __get__(self):
            return self.opts.bytes_per_sync
        def __set__(self, value):
            self.opts.bytes_per_sync = value

    property compaction_style:
        def __get__(self):
            if self.opts.compaction_style == kCompactionStyleLevel:
                return 'level'
            if self.opts.compaction_style == kCompactionStyleUniversal:
                return 'universal'
            raise Exception("Unknown compaction_style")

        def __set__(self, str value):
            if value == 'level':
                self.opts.compaction_style = kCompactionStyleLevel
            elif value == 'universal':
                self.opts.compaction_style = kCompactionStyleUniversal
            else:
                raise Exception("Unknown compaction style")

    property compaction_options_universal:
        def __get__(self):
            cdef universal_compaction.CompactionOptionsUniversal uopts
            cdef dict ret_ob = {}

            uopts = self.opts.compaction_options_universal

            ret_ob['size_ratio'] = uopts.size_ratio
            ret_ob['min_merge_width'] = uopts.min_merge_width
            ret_ob['max_merge_width'] = uopts.max_merge_width
            ret_ob['max_size_amplification_percent'] = uopts.max_size_amplification_percent
            ret_ob['compression_size_percent'] = uopts.compression_size_percent

            if uopts.stop_style == kCompactionStopStyleSimilarSize:
                ret_ob['stop_style'] = 'similar_size'
            elif uopts.stop_style == kCompactionStopStyleTotalSize:
                ret_ob['stop_style'] = 'total_size'
            else:
                raise Exception("Unknown compaction style")

            return ret_ob

        def __set__(self, dict value):
            cdef universal_compaction.CompactionOptionsUniversal* uopts
            uopts = cython.address(self.opts.compaction_options_universal)

            if 'size_ratio' in value:
                uopts.size_ratio  = value['size_ratio']

            if 'min_merge_width' in value:
                uopts.min_merge_width = value['min_merge_width']

            if 'max_merge_width' in value:
                uopts.max_merge_width = value['max_merge_width']

            if 'max_size_amplification_percent' in value:
                uopts.max_size_amplification_percent = value['max_size_amplification_percent']

            if 'compression_size_percent' in value:
                uopts.compression_size_percent = value['compression_size_percent']

            if 'stop_style' in value:
                if value['stop_style'] == 'similar_size':
                    uopts.stop_style = kCompactionStopStyleSimilarSize
                elif value['stop_style'] == 'total_size':
                    uopts.stop_style = kCompactionStopStyleTotalSize
                else:
                    raise Exception("Unknown compaction style")

    property max_sequential_skip_in_iterations:
        def __get__(self):
            return self.opts.max_sequential_skip_in_iterations
        def __set__(self, value):
            self.opts.max_sequential_skip_in_iterations = value

    property inplace_update_support:
        def __get__(self):
            return self.opts.inplace_update_support
        def __set__(self, value):
            self.opts.inplace_update_support = value

    property table_factory:
        def __get__(self):
            return self.py_table_factory

        def __set__(self, PyTableFactory value):
            self.py_table_factory = value
            self.opts.table_factory = value.get_table_factory()

    property memtable_factory:
        def __get__(self):
            return self.py_memtable_factory

        def __set__(self, PyMemtableFactory value):
            self.py_memtable_factory = value
            self.opts.memtable_factory = value.get_memtable_factory()

    property inplace_update_num_locks:
        def __get__(self):
            return self.opts.inplace_update_num_locks
        def __set__(self, value):
            self.opts.inplace_update_num_locks = value

    property comparator:
        def __get__(self):
            return self.py_comparator.get_ob()

        def __set__(self, value):
            if isinstance(value, PyComparator):
                if (<PyComparator?>value).get_comparator() == NULL:
                    raise Exception("Cannot set %s as comparator" % value)
                else:
                    self.py_comparator = value
            else:
                self.py_comparator = PyGenericComparator(value)

            self.opts.comparator = self.py_comparator.get_comparator()

    property merge_operator:
        def __get__(self):
            if self.py_merge_operator is None:
                return None
            return self.py_merge_operator.get_ob()

        def __set__(self, value):
            self.py_merge_operator = PyMergeOperator(value)
            self.opts.merge_operator = self.py_merge_operator.get_operator()

    property prefix_extractor:
        def __get__(self):
            if self.py_prefix_extractor is None:
                return None
            return self.py_prefix_extractor.get_ob()

        def __set__(self, value):
            self.py_prefix_extractor = PySliceTransform(value)
            self.opts.prefix_extractor = self.py_prefix_extractor.get_transformer()

    property row_cache:
        def __get__(self):
            return self.py_row_cache

        def __set__(self, value):
            if value is None:
                self.py_row_cache = None
                self.opts.row_cache.reset()
            elif not isinstance(value, PyCache):
                raise Exception("row_cache must be a Cache object")
            else:
                self.py_row_cache = value
                self.opts.row_cache = self.py_row_cache.get_cache()


# Forward declaration
cdef class Snapshot

cdef class KeysIterator
cdef class ValuesIterator
cdef class ItemsIterator
cdef class ReversedIterator

# Forward declaration
cdef class WriteBatchIterator

cdef class WriteBatch(object):
    cdef db.WriteBatch* batch

    def __cinit__(self, data=None):
        self.batch = NULL
        if data is not None:
            self.batch = new db.WriteBatch(bytes_to_string(data))
        else:
            self.batch = new db.WriteBatch()

    def __dealloc__(self):
        if not self.batch == NULL:
            del self.batch

    def put(self, key, value, ColumnFamilyHandle column_family=None):
        cdef db.ColumnFamilyHandle* cf_handle
        if column_family is None:
            self.batch.Put(bytes_to_slice(key), bytes_to_slice(value))
        else:
            cf_handle = column_family.handle
            if column_family.shared_column_family_prefix:
                key = column_family.shared_column_family_prefix_bytes + key
            self.batch.Put(cf_handle, bytes_to_slice(key), bytes_to_slice(value))

    def delete(self, key, ColumnFamilyHandle column_family=None):
        cdef db.ColumnFamilyHandle* cf_handle
        if column_family is None:
            self.batch.Delete(bytes_to_slice(key))
        else:
            cf_handle = column_family.handle
            if column_family.shared_column_family_prefix:
                key = column_family.shared_column_family_prefix_bytes + key
            self.batch.Delete(cf_handle, bytes_to_slice(key))

    def delete_range(self, ColumnFamilyHandle column_family, begin_key, end_key):
        cdef Status st
        cdef db.ColumnFamilyHandle* cf_handle = column_family.handle
        if column_family.shared_column_family_prefix:
            begin_key = column_family.shared_column_family_prefix_bytes + begin_key
            end_key = column_family.shared_column_family_prefix_bytes + end_key
        cdef Slice c_begin_key = bytes_to_slice(begin_key)
        cdef Slice c_end_key = bytes_to_slice(end_key)
        with nogil:
            self.batch.DeleteRange(cf_handle, c_begin_key, c_end_key)

    def clear(self):
        self.batch.Clear()

    def data(self):
        return string_to_bytes(self.batch.Data())

    def count(self):
        return self.batch.Count()

    def __iter__(self):
        return WriteBatchIterator(self)

    def get_pointer(self):
        return PyLong_FromVoidPtr(self.batch)

@cython.internal
cdef class WriteBatchIterator(object):
    # Need a reference to the WriteBatch.
    # The BatchItems are only pointers to the memory in WriteBatch.
    cdef WriteBatch batch
    cdef vector[db.BatchItem] items
    cdef size_t pos

    def __init__(self, WriteBatch batch):
        cdef Status st

        self.batch = batch
        self.pos = 0

        st = db.get_batch_items(batch.batch, cython.address(self.items))
        check_status(st)

    def __iter__(self):
        return self

    def __next__(self):
        if self.pos == self.items.size():
            raise StopIteration()

        cdef str op

        if self.items[self.pos].op == db.BatchItemOpPut:
            op = "Put"
        elif self.items[self.pos].op == db.BatchItemOpMerge:
            op = "Merge"
        elif self.items[self.pos].op == db.BatchItemOpDelte:
            op = "Delete"

        ret = (
            op,
            slice_to_bytes(self.items[self.pos].key),
            slice_to_bytes(self.items[self.pos].value))

        self.pos += 1
        return ret

@cython.no_gc_clear
cdef class DB(object):
    cdef Options combined_options
    cdef DBOptions db_options
    cdef db.DB* db
    cdef shared_ptr[db_DB] db_shared_ptr
    cdef dict cf_handles

    def __cinit__(self, db_name, DBOptions db_options, column_families=None, read_only=False,
                  Options combined_options=None
                  ):
        """
        :param combined_options: This is only specified when the database is opened without specifying any column_families.
        """
        cdef Status st
        cdef string db_path
        cdef vector[db.ColumnFamilyDescriptor] column_family_descs
        cdef vector[db.ColumnFamilyHandle*] column_family_handles
        cdef ColumnFamilyOptions column_family_options

        self.db = NULL
        self.combined_options = None
        self.db_options = None

        if combined_options is not None and combined_options.in_use:
            raise Exception("Options object is already used by another DB")
        if db_options is not None and db_options.in_use:
            raise Exception("DBOptions object is already used by another DB")

        db_path = path_to_string(db_name)

        if column_families is None:
            # No column_families was specified, so the combined_options parameter (which contains an 'options.Options'
            # instance that contain both DBOptions and ColumnFamiliyOptions) should have been specified.
            if combined_options is None:
                raise AssertionError("Neither the 'combined_options' nor the 'column_families' parameters was specified!")
            if db_options is not None:
                raise AssertionError("Both the 'combined_options' and 'db_options' parameters was specified!")
            if read_only:
                with nogil:
                    st = db.DB_OpenForReadOnly(
                        deref(combined_options.opts),
                        db_path,
                        cython.address(self.db),
                        False)
            else:
                with nogil:
                    st = db.DB_Open(
                        deref(combined_options.opts),
                        db_path,
                        cython.address(self.db))
            check_status(st)
        else:
            # column_families was specified, so the db_options parameter should be specified and the combined_options
            # parameter should be None.
            if db_options is None:
                raise AssertionError("column_families was defined, but the db_options parameters was None!")
            if combined_options is not None:
                raise AssertionError("Both the 'column_families' and 'combined_options' parameters was specified!")
            if isinstance(column_families, dict):
                for column_family_name, cf_opts in column_families.items():
                    column_family_options = cf_opts
                    column_family_descs.push_back(db.ColumnFamilyDescriptor(column_family_name, deref(column_family_options.opts)))
            else:
                for column_family_name in column_families:
                    column_family_descs.push_back(db.ColumnFamilyDescriptor(column_family_name, options.ColumnFamilyOptions()))

            if read_only:
                with nogil:
                    st = db.DB_OpenForReadOnly_ColumnFamilies(
                        deref(db_options.opts),
                        db_path,
                        column_family_descs,
                        cython.address(column_family_handles),
                        cython.address(self.db),
                        False)
            else:
                with nogil:
                    st = db.DB_Open_ColumnFamilies(
                        deref(db_options.opts),
                        db_path,
                        column_family_descs,
                        cython.address(column_family_handles),
                        cython.address(self.db))
            check_status(st)

            self.cf_handles = {}
            for column_family_handle in column_family_handles:
                cf_handle = ColumnFamilyHandle()
                cf_handle.handle = column_family_handle
                self.cf_handles[column_family_handle.GetName()] = cf_handle

        # At this point the database object has been created, so we can store it in a smart_ptr
        self.db_shared_ptr = shared_ptr[db.DB](self.db)

        # Inject the loggers into the python callbacks
        cdef shared_ptr[logger.Logger] info_log = self.db.GetOptions().info_log

        if combined_options is not None:
            if combined_options.py_comparator is not None:
                combined_options.py_comparator.set_info_log(info_log)

            if combined_options.py_table_factory is not None:
                combined_options.py_table_factory.set_info_log(info_log)

            if combined_options.prefix_extractor is not None:
                combined_options.py_prefix_extractor.set_info_log(info_log)

        self.combined_options = combined_options
        if combined_options is not None:
            self.combined_options.in_use = True
        self.db_options = db_options
        if db_options is not None:
            self.db_options.in_use = True

    def close(self):
        cdef Status status
        status = self.db.Close()
        check_status(status)

    def get_pointer(self):
        return PyLong_FromVoidPtr(self.db)

    def get_shared_pointer(self):
        return PyLong_FromVoidPtr(&self.db_shared_ptr)

    def cancel_all_background_work(self):
        cdef db.DB* my_db = self.db
        cdef cpp_bool wait = True;
        if not my_db == NULL:
            with nogil:
                db.CancelAllBackgroundWork(my_db, wait)

    def __dealloc__(self):
        cdef db.DB* my_db = self.db
        cdef cpp_bool wait = True;
        if my_db != NULL:
            self.cf_handles = None
            with nogil:
                self.db = NULL
                # Release the smart_ptr; if this is the last reference the db.DB object will be deleted.
                self.db_shared_ptr.reset()

        if self.combined_options is not None:
            self.combined_options.in_use = False
        if self.db_options is not None:
            self.db_options.in_use = False

    property column_family_handles:
        def __get__(self):
            return self.cf_handles

    def get_column_family_handle(self, name):
        return self.cf_handles[name]

    def put(self, key, value, ColumnFamilyHandle column_family=None, sync=False, disable_wal=False):
        cdef Status st
        cdef options.WriteOptions opts
        cdef db.ColumnFamilyHandle* cf_handle
        opts.sync = sync
        opts.disableWAL = disable_wal

        cdef Slice c_key
        cdef Slice c_value = bytes_to_slice(value)

        if column_family is None:
            c_key = bytes_to_slice(key)
            with nogil:
                st = self.db.Put(opts, c_key, c_value)
        else:
            cf_handle = column_family.handle
            if column_family.shared_column_family_prefix:
                key = column_family.shared_column_family_prefix_bytes + key
            c_key = bytes_to_slice(key)
            with nogil:
                st = self.db.Put(opts, cf_handle, c_key, c_value)
        check_status(st)

    def delete(self, key, ColumnFamilyHandle column_family=None, sync=False, disable_wal=False):
        cdef Status st
        cdef options.WriteOptions opts
        cdef db.ColumnFamilyHandle* cf_handle
        opts.sync = sync
        opts.disableWAL = disable_wal

        cdef Slice c_key

        if column_family is None:
            c_key = bytes_to_slice(key)
            with nogil:
                st = self.db.Delete(opts, c_key)
        else:
            cf_handle = column_family.handle
            if column_family.shared_column_family_prefix:
                key = column_family.shared_column_family_prefix_bytes + key
            c_key = bytes_to_slice(key)
            with nogil:
                st = self.db.Delete(opts, cf_handle, c_key)
        check_status(st)

    def delete_range(self, ColumnFamilyHandle column_family, begin_key, end_key):
        cdef Status st
        cdef options.WriteOptions opts
        cdef db.ColumnFamilyHandle* cf_handle = column_family.handle

        if column_family.shared_column_family_prefix:
            begin_key = column_family.shared_column_family_prefix_bytes + begin_key
            end_key = column_family.shared_column_family_prefix_bytes + end_key

        cdef Slice c_begin_key = bytes_to_slice(begin_key)
        cdef Slice c_end_key = bytes_to_slice(end_key)
        with nogil:
            st = self.db.DeleteRange(opts, cf_handle, c_begin_key, c_end_key)
        check_status(st)

    def write(self, WriteBatch batch, sync=False, disable_wal=False):
        cdef Status st
        cdef options.WriteOptions opts
        opts.sync = sync
        opts.disableWAL = disable_wal

        with nogil:
            st = self.db.Write(opts, batch.batch)
        check_status(st)

    def get(self, key, ColumnFamilyHandle column_family=None, *args, **kwargs):
        cdef string res
        cdef Status st
        cdef options.ReadOptions opts
        cdef db.ColumnFamilyHandle* cf_handle

        opts = self.build_read_opts(self.__parse_read_opts(*args, **kwargs))
        cdef Slice c_key

        if column_family is None:
            c_key = bytes_to_slice(key)
            with nogil:
                st = self.db.Get(opts, c_key, cython.address(res))
        else:
            cf_handle = column_family.handle
            if column_family.shared_column_family_prefix:
                key = column_family.shared_column_family_prefix_bytes + key
            c_key = bytes_to_slice(key)
            with nogil:
                st = self.db.Get(opts, cf_handle, c_key, cython.address(res))

        if st.ok():
            return string_to_bytes(res)
        elif st.IsNotFound():
            return None
        else:
            check_status(st)

    def iterkeys(self, ColumnFamilyHandle column_family=None, *args, **kwargs):
        cdef options.ReadOptions opts
        cdef db.ColumnFamilyHandle* cf_handle
        cdef KeysIterator it

        opts = self.build_read_opts(self.__parse_read_opts(*args, **kwargs))
        it = KeysIterator(self, column_family)

        if column_family is None:
            with nogil:
                it.ptr = self.db.NewIterator(opts)
        else:
            cf_handle = column_family.handle
            if column_family.shared_column_family_prefix:
                opts.iterate_lower_bound = &column_family.shared_column_family_prefix_slice
                opts.iterate_upper_bound = &column_family.shared_column_family_prefix_iterate_upper_bound_slice
            with nogil:
                it.ptr = self.db.NewIterator(opts, cf_handle)

        return it

    def itervalues(self, ColumnFamilyHandle column_family=None, *args, **kwargs):
        cdef options.ReadOptions opts
        cdef db.ColumnFamilyHandle* cf_handle
        cdef ValuesIterator it

        opts = self.build_read_opts(self.__parse_read_opts(*args, **kwargs))

        it = ValuesIterator(self, column_family)

        if column_family is None:
            with nogil:
                it.ptr = self.db.NewIterator(opts)
        else:
            cf_handle = column_family.handle
            if column_family.shared_column_family_prefix:
                opts.iterate_lower_bound = &column_family.shared_column_family_prefix_slice
                opts.iterate_upper_bound = &column_family.shared_column_family_prefix_iterate_upper_bound_slice
            with nogil:
                it.ptr = self.db.NewIterator(opts, cf_handle)

        return it

    def iteritems(self, ColumnFamilyHandle column_family=None, *args, **kwargs):
        cdef options.ReadOptions opts
        cdef db.ColumnFamilyHandle* cf_handle
        cdef ItemsIterator it

        opts = self.build_read_opts(self.__parse_read_opts(*args, **kwargs))

        it = ItemsIterator(self, column_family)

        if column_family is None:
            with nogil:
                it.ptr = self.db.NewIterator(opts)
        else:
            cf_handle = column_family.handle
            if column_family.shared_column_family_prefix:
                opts.iterate_lower_bound = &column_family.shared_column_family_prefix_slice
                opts.iterate_upper_bound = &column_family.shared_column_family_prefix_iterate_upper_bound_slice
            with nogil:
                it.ptr = self.db.NewIterator(opts, cf_handle)

        return it

    def snapshot(self):
        return Snapshot(self)

    def get_property(self, prop, ColumnFamilyHandle column_family=None):
        cdef string value
        cdef Slice c_prop = bytes_to_slice(prop)
        cdef cpp_bool ret = False
        cdef db.ColumnFamilyHandle* cf_handle

        if column_family is None:
            with nogil:
                ret = self.db.GetProperty(c_prop, cython.address(value))
        else:
            cf_handle = column_family.handle
            with nogil:
                ret = self.db.GetProperty(cf_handle, c_prop, cython.address(value))

        if ret:
            return string_to_bytes(value)
        else:
            return None

    def get_live_files_metadata(self):
        cdef vector[db.LiveFileMetaData] metadata

        with nogil:
            self.db.GetLiveFilesMetaData(cython.address(metadata))

        ret = []
        for ob in metadata:
            t = {}
            t['column_family_name'] = ob.column_family_name
            t['name'] = string_to_path(ob.name)
            t['level'] = ob.level
            t['size'] = ob.size
            t['smallestkey'] = string_to_bytes(ob.smallestkey)
            t['largestkey'] = string_to_bytes(ob.largestkey)
            t['smallest_seqno'] = ob.smallest_seqno
            t['largest_seqno'] = ob.largest_seqno

            ret.append(t)

        return ret

    def compact_range(self, ColumnFamilyHandle column_family=None, begin=None, end=None, **py_options):
        cdef options.CompactRangeOptions c_options

        c_options.change_level = py_options.get('change_level', False)
        c_options.target_level = py_options.get('target_level', -1)

        blc = py_options.get('bottommost_level_compaction', 'if_compaction_filter')
        if blc == 'skip':
            c_options.bottommost_level_compaction = options.blc_skip
        elif blc == 'if_compaction_filter':
            c_options.bottommost_level_compaction = options.blc_is_filter
        elif blc == 'force':
            c_options.bottommost_level_compaction = options.blc_force
        else:
            raise ValueError("bottommost_level_compaction is not valid")

        cdef Status st
        cdef Slice begin_val
        cdef Slice end_val

        cdef Slice* begin_ptr
        cdef Slice* end_ptr

        begin_ptr = NULL
        end_ptr = NULL

        if begin is not None:
            begin_val = bytes_to_slice(begin)
            begin_ptr = cython.address(begin_val)

        if end is not None:
            end_val = bytes_to_slice(end)
            end_ptr = cython.address(end_val)

        if column_family is None:
            with nogil:
                st = self.db.CompactRange(c_options, begin_ptr, end_ptr)
        else:
            cf_handle = column_family.handle
            with nogil:
                st = self.db.CompactRange(c_options, cf_handle, begin_ptr, end_ptr)

        check_status(st)

    def create_column_family(self, name, ColumnFamilyOptions column_family_options=None):
        cdef db.ColumnFamilyHandle* cf_handle
        cdef Status st
        cdef options.ColumnFamilyOptions coptions

        if column_family_options is None:
            coptions = options.ColumnFamilyOptions()
        else:
            coptions = deref(column_family_options.opts)

        st = self.db.CreateColumnFamily(coptions, name, &cf_handle)
        check_status(st)

        pcf_handle = ColumnFamilyHandle()
        pcf_handle.handle = cf_handle
        self.cf_handles[name] = pcf_handle
        return pcf_handle

    def drop_column_family(self, name):
        cdef ColumnFamilyHandle pcf_handle
        cdef db.ColumnFamilyHandle* cf_handle
        cdef Status st

        pcf_handle = self.cf_handles[name]
        cf_handle = pcf_handle.handle
        with nogil:
           st = self.db.DropColumnFamily(cf_handle)
        check_status(st)
        del self.cf_handles[name]

    @staticmethod
    def __parse_read_opts(
        verify_checksums=False,
        fill_cache=True,
        snapshot=None,
        read_tier="all"):
        # NOTE: Never add the "iterate_lower_bound" or "iterate_upper_bound" properties to this method! Those properties
        #       are used internally to handle shared_column_family_prefix values and should be be settable from the
        #       python code.
        # TODO: Is this really effiencet ?
        return locals()

    cdef options.ReadOptions build_read_opts(self, dict py_opts):
        cdef options.ReadOptions opts
        opts.verify_checksums = py_opts['verify_checksums']
        opts.fill_cache = py_opts['fill_cache']
        if py_opts['snapshot'] is not None:
            opts.snapshot = (<Snapshot?>(py_opts['snapshot'])).ptr

        if py_opts['read_tier'] == "all":
            opts.read_tier = options.kReadAllTier
        elif py_opts['read_tier'] == 'cache':
            opts.read_tier = options.kBlockCacheTier
        else:
            raise ValueError("Invalid read_tier")

        return opts

    property options:
        def __get__(self):
            if self.combined_options is None:
                return self.db_options
            return self.combined_options


def repair_db(db_name, Options opts):
    cdef Status st
    cdef string db_path

    db_path = path_to_string(db_name)
    st = db.RepairDB(db_path, deref(opts.opts))
    check_status(st)


def list_column_families(db_name, DBOptions opts):
    cdef Status st
    cdef string db_path
    cdef vector[string] column_families

    db_path = path_to_string(db_name)
    st = db.ListColumnFamilies(deref(opts.opts), db_path, &column_families)
    check_status(st)

    ret = []
    for cf in column_families:
        ret.append(cf)
    return ret


@cython.no_gc_clear
@cython.internal
cdef class Snapshot(object):
    cdef const snapshot.Snapshot* ptr
    cdef DB db

    def __cinit__(self, DB db):
        self.db = db
        self.ptr = NULL
        with nogil:
            self.ptr = db.db.GetSnapshot()

    def __dealloc__(self):
        if not self.ptr == NULL:
            with nogil:
                self.db.db.ReleaseSnapshot(self.ptr)


@cython.internal
cdef class BaseIterator(object):
    cdef iterator.Iterator* ptr
    cdef DB db
    cdef ColumnFamilyHandle column_family
    cdef uint32_t shared_column_family_prefix
    cdef bytes shared_column_family_prefix_bytes
    cdef Slice shared_column_family_prefix_slice
    cdef Slice shared_column_family_prefix_iterate_upper_bound_slice

    def __cinit__(self, DB db, ColumnFamilyHandle column_family):
        self.db = db
        self.ptr = NULL
        self.column_family = column_family
        if column_family is not None:
            self.shared_column_family_prefix = column_family.shared_column_family_prefix
            self.shared_column_family_prefix_bytes = column_family.shared_column_family_prefix_bytes
            self.shared_column_family_prefix_slice = column_family.shared_column_family_prefix_slice
            self.shared_column_family_prefix_iterate_upper_bound_slice = column_family.shared_column_family_prefix_iterate_upper_bound_slice
        else:
            self.shared_column_family_prefix = 0

    def __dealloc__(self):
        if not self.ptr == NULL:
            del self.ptr

    def __iter__(self):
        return self

    def __next__(self):
        if not self.Valid():
            raise StopIteration()

        cdef object ret = self.get_ob()
        with nogil:
            self.ptr.Next()
        check_status(self.ptr.status())
        return ret

    def __reversed__(self):
        return ReversedIterator(self)

    cpdef Valid(self):
        cdef Slice c_key
        if not self.ptr.Valid():
            return False
        if self.shared_column_family_prefix:
            with nogil:
                c_key = self.ptr.key()
            if not c_key.starts_with(self.shared_column_family_prefix_slice):
                # the iterator points outside the specified part of the shared columnfamily, so it is invalid
                return False
        return True

    cpdef seek_to_first(self):
        if self.shared_column_family_prefix:
            with nogil:
                self.ptr.Seek(self.shared_column_family_prefix_slice)
        else:
            with nogil:
                self.ptr.SeekToFirst()
        check_status(self.ptr.status())

    cpdef seek_to_last(self):
        cdef Slice c_key
        if self.shared_column_family_prefix:
            with nogil:
                self.ptr.Seek(self.shared_column_family_prefix_iterate_upper_bound_slice)
                if self.ptr.Valid():
                    c_key = self.ptr.key()
                    if c_key.starts_with(self.shared_column_family_prefix_iterate_upper_bound_slice):
                        # We found an entity in the next sub-columnfamily, so try to take one step backwards
                        self.ptr.Prev()
        else:
            with nogil:
                self.ptr.SeekToLast()
        check_status(self.ptr.status())

    cpdef seek(self, key):
        if self.shared_column_family_prefix:
            key = self.shared_column_family_prefix_bytes + key
        cdef Slice c_key = bytes_to_slice(key)
        with nogil:
            self.ptr.Seek(c_key)
        check_status(self.ptr.status())

    cdef object get_ob(self):
        return None

@cython.internal
cdef class KeysIterator(BaseIterator):
    cdef object get_ob(self):
        cdef Slice c_key
        with nogil:
            c_key = self.ptr.key()
        check_status(self.ptr.status())
        key = slice_to_bytes(c_key)
        if self.shared_column_family_prefix:
            key = key[len(self.shared_column_family_prefix_bytes):]
        return key

@cython.internal
cdef class ValuesIterator(BaseIterator):
    cdef object get_ob(self):
        cdef Slice c_value
        with nogil:
            c_value = self.ptr.value()
        check_status(self.ptr.status())
        return slice_to_bytes(c_value)

@cython.internal
cdef class ItemsIterator(BaseIterator):
    cdef object get_ob(self):
        cdef Slice c_key
        cdef Slice c_value
        with nogil:
            c_key = self.ptr.key()
            c_value = self.ptr.value()
        check_status(self.ptr.status())
        key = slice_to_bytes(c_key)
        if self.shared_column_family_prefix:
            key = key[len(self.shared_column_family_prefix_bytes):]
        return (key, slice_to_bytes(c_value))

@cython.internal
cdef class ReversedIterator(object):
    cdef BaseIterator it

    def __cinit__(self, BaseIterator it):
        self.it = it

    def seek_to_first(self):
        self.it.seek_to_first()

    def seek_to_last(self):
        self.it.seek_to_last()

    def seek(self, key):
        self.it.seek(key)

    def __iter__(self):
        return self

    def __reversed__(self):
        return self.it

    def __next__(self):
        if not self.it.Valid():
            raise StopIteration()

        cdef object ret = self.it.get_ob()
        with nogil:
            self.it.ptr.Prev()
        check_status(self.it.ptr.status())
        return ret

cdef class BackupEngine(object):
    cdef backup.BackupEngine* engine

    def  __cinit__(self, backup_dir):
        cdef Status st
        cdef string c_backup_dir
        self.engine = NULL

        c_backup_dir = path_to_string(backup_dir)
        st = backup.BackupEngine_Open(
            env.Env_Default(),
            backup.BackupEngineOptions(c_backup_dir),
            cython.address(self.engine))

        check_status(st)

    def __dealloc__(self):
        if not self.engine == NULL:
            with nogil:
                del self.engine

    def create_backup(self, DB db, flush_before_backup=False):
        cdef Status st
        cdef cpp_bool c_flush_before_backup

        c_flush_before_backup = flush_before_backup

        with nogil:
            st = self.engine.CreateNewBackup(db.db, c_flush_before_backup)
        check_status(st)

    def restore_backup(self, backup_id, db_dir, wal_dir):
        cdef Status st
        cdef backup.BackupID c_backup_id
        cdef string c_db_dir
        cdef string c_wal_dir

        c_backup_id = backup_id
        c_db_dir = path_to_string(db_dir)
        c_wal_dir = path_to_string(wal_dir)

        with nogil:
            st = self.engine.RestoreDBFromBackup(
                c_backup_id,
                c_db_dir,
                c_wal_dir)

        check_status(st)

    def restore_latest_backup(self, db_dir, wal_dir):
        cdef Status st
        cdef string c_db_dir
        cdef string c_wal_dir

        c_db_dir = path_to_string(db_dir)
        c_wal_dir = path_to_string(wal_dir)

        with nogil:
            st = self.engine.RestoreDBFromLatestBackup(c_db_dir, c_wal_dir)

        check_status(st)

    def stop_backup(self):
        with nogil:
            self.engine.StopBackup()

    def garbage_collect(self):
        with nogil:
            self.engine.GarbageCollect()

    def purge_old_backups(self, num_backups_to_keep):
        cdef Status st
        cdef uint32_t c_num_backups_to_keep

        c_num_backups_to_keep = num_backups_to_keep

        with nogil:
            st = self.engine.PurgeOldBackups(c_num_backups_to_keep)
        check_status(st)

    def delete_backup(self, backup_id):
        cdef Status st
        cdef backup.BackupID c_backup_id

        c_backup_id = backup_id

        with nogil:
            st = self.engine.DeleteBackup(c_backup_id)

        check_status(st)

    def get_backup_info(self):
        cdef vector[backup.BackupInfo] backup_info

        with nogil:
            self.engine.GetBackupInfo(cython.address(backup_info))

        ret = []
        for ob in backup_info:
            t = {}
            t['backup_id'] = ob.backup_id
            t['timestamp'] = ob.timestamp
            t['size'] = ob.size
            ret.append(t)

        return ret

cdef class Checkpoint(object):
    cdef checkpoint.Checkpoint* cpoint

    def  __cinit__(self, DB db):
        cdef Status st
        self.cpoint = NULL

        st = checkpoint.Checkpoint_Create(
            db.db,
            cython.address(self.cpoint))

        check_status(st)

    def __dealloc__(self):
        if not self.cpoint == NULL:
            with nogil:
                del self.cpoint

    def create_checkpoint(self, checkpoint_dir):
        cdef Status st
        cdef string c_checkpoint_dir
        cdef uint64_t c_log_size_for_flush

        c_checkpoint_dir = path_to_string(checkpoint_dir)

        with nogil:
            st = self.cpoint.CreateCheckpoint(
                c_checkpoint_dir)
        check_status(st)


cdef class MemoryUtil:
    @staticmethod
    def GetApproximateMemoryUsageByType(py_db):
        cdef vector[db.DB*] dbs
        cdef unordered_set[const cache.Cache*] cache_set
        cdef cpp_map[memory_util.MemoryUtil_UsageType, uint64_t] usage_by_type
        cdef db.DB* c_db = <db.DB*>PyLong_AsVoidPtr(py_db.get_pointer())
        dbs.push_back(c_db)
        memory_util.MemoryUtil.GetApproximateMemoryUsageByType(dbs, cache_set, &usage_by_type)
        py_usage_by_type = {}
        for item in usage_by_type:
            type_as_int = item.first
            value = item.second
            if type_as_int == memory_util.MemoryUtil_UsageType.kMemTableTotal:
                py_usage_by_type["kMemTableTotal"] = value
            elif type_as_int == memory_util.MemoryUtil_UsageType.kMemTableUnFlushed:
                py_usage_by_type["kMemTableUnFlushed"] = value
            elif type_as_int == memory_util.MemoryUtil_UsageType.kTableReadersTotal:
                py_usage_by_type["kTableReadersTotal"] = value
            elif type_as_int == memory_util.MemoryUtil_UsageType.kCacheTotal:
                py_usage_by_type["kCacheTotal"] = value
            else:
                raise AssertionError(f"Unknown usagetype: {type_as_int}")
        return py_usage_by_type
