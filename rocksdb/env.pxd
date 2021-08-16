cdef extern from "rocksdb/env.h" namespace "rocksdb::Env":
    ctypedef enum Env_Priority "rocksdb::Env::Priority":
        BOTTOM
        LOW
        HIGH
        USER
        TOTAL

cdef extern from "rocksdb/env.h" namespace "rocksdb":
    cdef cppclass Env:
        Env()
        void SetBackgroundThreads(int number, Env_Priority pri)


    cdef Env* Env_Default "rocksdb::Env::Default"()

