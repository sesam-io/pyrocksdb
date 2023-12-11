cdef extern from "rocksdb/db.h" namespace "rocksdb":
    cdef cppclass Snapshot:
        pass


cdef extern from "cpp/default_thread_local_snapshot.hpp" namespace "py_rocks":
    cdef cppclass DefaultThreadLocalSnapshot:
        @staticmethod
        const Snapshot* get_default_snapshot() nogil except +
        @staticmethod
        void set_default_snapshot(Snapshot* snapshot)  nogil except +
