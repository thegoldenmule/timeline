import Foundation
import GRDB

/// The schema of `project.sqlite` (storage.md sections 4 and 5) and the connection configuration
/// (section 3). Every table is STRICT; JSON is TEXT; times are `_v` / `_ts` integer pairs.
enum Schema {
    /// The stream id of every event while projects hold one sequence (storage.md section 4).
    static let streamId = "project"

    /// The `Configuration` of storage.md section 3: foreign keys on, 5 s writer busy timeout (readers keep
    /// `DatabasePool`'s 10 s default; `readonlyBusyMode` is not public in GRDB 7.11), `synchronous=NORMAL`
    /// under WAL (or `FULL` under DELETE).
    static func configuration(journal: SQLiteProjectStore.JournalMode, label: String) -> Configuration {
        var config = Configuration()
        config.label = label
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)  // readers use DatabasePool's 10 s default
        config.prepareDatabase { db in
            switch journal {
            case .wal:
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            case .delete:
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
                try db.execute(sql: "PRAGMA synchronous = FULL")
            }
        }
        return config
    }

    /// `PRAGMA user_version` after the latest migration, for tooling that reads it.
    static let currentUserVersion = 2

    /// Migrations are named `v<n>`; each one also sets `PRAGMA user_version = n` (GRDB tracks what ran in
    /// its own `grdb_migrations` table, which is the source of truth).
    static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: v1)
            try db.execute(sql: "PRAGMA user_version = 1")
        }
        m.registerMigration("v2") { db in
            try db.execute(sql: v2)
            try db.execute(sql: "PRAGMA user_version = 2")
        }
        return m
    }()

    static let v1 = """
        -- Append-only. Never UPDATE or DELETE rows here.
        CREATE TABLE events (
          seq            INTEGER PRIMARY KEY,
          event_id       TEXT    NOT NULL UNIQUE,
          stream_id      TEXT    NOT NULL,
          stream_version INTEGER NOT NULL,
          type           TEXT    NOT NULL,
          schema_version INTEGER NOT NULL DEFAULT 1,
          payload        TEXT    NOT NULL,
          occurred_at    TEXT    NOT NULL,
          actor          TEXT    NOT NULL,
          txn_id         TEXT    NOT NULL,
          command_id     TEXT    NOT NULL,
          causation_id   TEXT,
          metadata       TEXT,
          clip_id        TEXT AS (json_extract(payload, '$.clipId')) VIRTUAL,
          sequence_id    TEXT AS (json_extract(payload, '$.sequenceId')) VIRTUAL,
          UNIQUE (stream_id, stream_version)
        ) STRICT;
        CREATE INDEX events_clip_idx ON events(clip_id) WHERE clip_id IS NOT NULL;
        CREATE INDEX events_sequence_idx ON events(sequence_id, seq) WHERE sequence_id IS NOT NULL;
        CREATE INDEX events_type_idx ON events(type);
        CREATE INDEX events_txn_idx  ON events(txn_id, seq);

        CREATE TABLE commands (
          command_id   TEXT PRIMARY KEY,
          received_at  TEXT NOT NULL,
          actor        TEXT NOT NULL,
          name         TEXT NOT NULL,
          args         TEXT NOT NULL,
          result       TEXT NOT NULL,
          status       TEXT NOT NULL CHECK (status IN ('applied','stale','invalid','noop'))
        ) STRICT;

        CREATE TABLE project_state (
          id           INTEGER PRIMARY KEY CHECK (id = 1),
          version      INTEGER NOT NULL,
          last_seq     INTEGER NOT NULL,
          state        TEXT    NOT NULL
        ) STRICT;

        CREATE TABLE assets (
          asset_id      TEXT PRIMARY KEY,
          content_hash  TEXT NOT NULL,
          kind          TEXT NOT NULL CHECK (kind IN ('video','audio','image')),
          library_path  TEXT NOT NULL,
          display_name  TEXT NOT NULL,
          duration_v    INTEGER NOT NULL, duration_ts INTEGER NOT NULL CHECK (duration_ts > 0),
          has_video     INTEGER NOT NULL, has_audio INTEGER NOT NULL,
          offline       INTEGER NOT NULL DEFAULT 0,
          probe         TEXT
        ) STRICT;

        CREATE TABLE sequences (
          sequence_id TEXT PRIMARY KEY, name TEXT NOT NULL,
          frame_v INTEGER NOT NULL, frame_ts INTEGER NOT NULL CHECK (frame_ts > 0),
          width INTEGER NOT NULL, height INTEGER NOT NULL
        ) STRICT;

        CREATE TABLE tracks (
          track_id    TEXT PRIMARY KEY,
          sequence_id TEXT NOT NULL REFERENCES sequences(sequence_id),
          kind        TEXT NOT NULL CHECK (kind IN ('video','audio','caption')),
          position    INTEGER NOT NULL,
          name        TEXT NOT NULL,
          muted       INTEGER NOT NULL DEFAULT 0,
          locked      INTEGER NOT NULL DEFAULT 0
        ) STRICT;

        CREATE TABLE clips (
          clip_id       TEXT PRIMARY KEY,
          sequence_id   TEXT NOT NULL REFERENCES sequences(sequence_id),
          track_id      TEXT NOT NULL REFERENCES tracks(track_id),
          asset_id      TEXT REFERENCES assets(asset_id),
          link_group_id TEXT,
          start_v       INTEGER NOT NULL, start_ts INTEGER NOT NULL CHECK (start_ts > 0),
          in_v          INTEGER NOT NULL, in_ts    INTEGER NOT NULL CHECK (in_ts > 0),
          out_v         INTEGER NOT NULL, out_ts   INTEGER NOT NULL CHECK (out_ts > 0),
          speed_num     INTEGER NOT NULL DEFAULT 1, speed_den INTEGER NOT NULL DEFAULT 1,
          text          TEXT,
          props         TEXT
        ) STRICT;
        CREATE INDEX clips_track_start_idx ON clips(track_id, start_v);
        CREATE INDEX clips_asset_idx ON clips(asset_id);
        CREATE INDEX clips_link_idx ON clips(link_group_id) WHERE link_group_id IS NOT NULL;

        CREATE TABLE transitions (
          transition_id TEXT PRIMARY KEY,
          sequence_id   TEXT NOT NULL REFERENCES sequences(sequence_id),
          track_id      TEXT NOT NULL REFERENCES tracks(track_id),
          left_clip_id  TEXT NOT NULL REFERENCES clips(clip_id),
          right_clip_id TEXT NOT NULL REFERENCES clips(clip_id),
          kind TEXT NOT NULL, duration_v INTEGER NOT NULL, duration_ts INTEGER NOT NULL CHECK (duration_ts > 0),
          alignment TEXT NOT NULL CHECK (alignment IN ('centered','startOnCut','endOnCut')),
          params TEXT
        ) STRICT;

        CREATE TABLE markers (
          marker_id TEXT PRIMARY KEY, sequence_id TEXT NOT NULL REFERENCES sequences(sequence_id),
          at_v INTEGER NOT NULL, at_ts INTEGER NOT NULL CHECK (at_ts > 0),
          label TEXT NOT NULL, colour TEXT
        ) STRICT;

        CREATE TABLE renders (
          render_id TEXT PRIMARY KEY, requested_at TEXT NOT NULL, completed_at TEXT,
          sequence_id TEXT NOT NULL, preset TEXT NOT NULL,
          output_path TEXT, output_hash TEXT,
          project_version INTEGER NOT NULL,
          status TEXT NOT NULL CHECK (status IN ('queued','running','done','failed','cancelled')),
          receipt TEXT
        ) STRICT;

        CREATE TABLE history (
          txn_id      TEXT PRIMARY KEY,
          first_seq   INTEGER NOT NULL, last_seq INTEGER NOT NULL,
          actor       TEXT NOT NULL,
          label       TEXT NOT NULL,
          kind        TEXT NOT NULL CHECK (kind IN ('edit','undo','redo')),
          target_txn  TEXT,
          live        INTEGER NOT NULL
        ) STRICT;

        CREATE TABLE projection_state (
          name     TEXT PRIMARY KEY,
          last_seq INTEGER NOT NULL,
          note     TEXT
        ) STRICT;
        """

    /// The `publishes` ledger next to `renders` (publish-plan.md section 4.2). Operational rows: never an
    /// event, never a projection, so `rebuildProjections` leaves them alone and `VACUUM INTO` carries them.
    static let v2 = """
        CREATE TABLE publishes (                        -- operational, not part of the event stream
          publish_id      TEXT PRIMARY KEY,
          render_id       TEXT NOT NULL REFERENCES renders(render_id),
          destination     TEXT NOT NULL CHECK (destination IN ('youtube')),
          account_id      TEXT NOT NULL,                -- provider subject; the account record lives outside the project
          requested_at    TEXT NOT NULL,
          completed_at    TEXT,
          status          TEXT NOT NULL CHECK (status IN ('queued','uploading','processing','done','failed','cancelled')),
          request         TEXT NOT NULL,                -- JSON PublishRequest (no secrets by construction)
          session         TEXT,                         -- JSON PublishSession: upload URI + bytes confirmed, for resume
          bytes_total     INTEGER,
          bytes_sent      INTEGER,
          remote_id       TEXT,
          remote_url      TEXT,
          project_version INTEGER NOT NULL,             -- copied from the render row at request time
          receipt         TEXT,                         -- JSON PublishReceipt
          error           TEXT
        ) STRICT;
        CREATE INDEX publishes_render_idx ON publishes(render_id, requested_at);
        CREATE INDEX publishes_active_idx ON publishes(status) WHERE status IN ('queued','uploading','processing');
        """

    /// The projection tables `rebuildProjections` truncates, in an order foreign keys accept. `renders` and
    /// `publishes` are not projections and are never truncated.
    static let queryTablesInDeleteOrder = ["transitions", "markers", "clips", "tracks", "sequences", "assets"]

    /// Names of the `projection_state` rows.
    enum Projection {
        static let projectState = "project_state"
        static let queryTables = "query_tables"
        static let history = "history"
        static let session = "session"
    }

    /// ISO-8601 UTC with milliseconds, the `occurred_at` / `received_at` format.
    static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func timestamp(_ date: Date) -> String { iso8601.format(date) }

    static func date(_ string: String) throws -> Date {
        if let d = try? iso8601.parse(string) { return d }
        return try Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(string)
    }
}
