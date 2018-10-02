from libcpp.string cimport string
from libc.stdint cimport uint64_t

from status cimport Status
from db cimport DB

cdef extern from "rocksdb/utilities/checkpoint.h" namespace "rocksdb":

    cdef cppclass Checkpoint:
        Status CreateCheckpoint(const string&) nogil except+

    cdef Status Checkpoint_Create "rocksdb::Checkpoint::Create"(
            DB*,
            Checkpoint**)
