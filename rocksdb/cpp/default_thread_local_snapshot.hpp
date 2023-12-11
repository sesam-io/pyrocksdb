#include "rocksdb/snapshot.h"

namespace py_rocks {

    // This class is used in instances where it is inconvenient to explicitly pass along a Snapshot object to all
    // the places where it is needed.
    class DefaultThreadLocalSnapshot {
        public:
            static const rocksdb::Snapshot* get_default_snapshot() {
                return DefaultThreadLocalSnapshot::thread_local_default_snapshot;
            }

            static void set_default_snapshot(const rocksdb::Snapshot* snapshot) {
                DefaultThreadLocalSnapshot::thread_local_default_snapshot = snapshot;
            }
        private:
            thread_local static const rocksdb::Snapshot* thread_local_default_snapshot;
    };

    thread_local const rocksdb::Snapshot* DefaultThreadLocalSnapshot::thread_local_default_snapshot = NULL;
}
