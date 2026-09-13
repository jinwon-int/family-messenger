package chat

// Frozen schema steps 3..12 (native MLS transport and successor stages).
//
// Decision D (docs/DECISION-2026-09-13-MATRIX-CRYPTO-STACK.md) moved the code
// that wrote these tables to archive/native-mls/. The migrations themselves stay
// so that Open still upgrades every existing database to schema 12 exactly as
// before and keeps the same pre-migration snapshots; no table is dropped or
// altered. The SQL below is byte-identical to the archived originals. Schema 13
// is not to be added here.

import "database/sql"

func migrateMLS(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v2-before-mls-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_rooms(room TEXT PRIMARY KEY REFERENCES rooms(id), group_id TEXT UNIQUE, creator TEXT NOT NULL, peer TEXT NOT NULL, pins BLOB NOT NULL, revision INTEGER NOT NULL, epoch INTEGER NOT NULL, phase TEXT NOT NULL, next_seq INTEGER NOT NULL);
 CREATE TABLE mls_events(room TEXT NOT NULL REFERENCES mls_rooms(room), seq INTEGER NOT NULL, device TEXT NOT NULL, client_id TEXT NOT NULL, request BLOB NOT NULL, sha256 TEXT NOT NULL, revision INTEGER NOT NULL, epoch INTEGER NOT NULL, PRIMARY KEY(room,seq), UNIQUE(room,device,client_id));
 PRAGMA user_version=3; COMMIT;`)
	return e
}

func migratePreparation(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v3-before-preparation-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_preparations(room TEXT PRIMARY KEY REFERENCES mls_rooms(room), source_room TEXT NOT NULL REFERENCES mls_rooms(room), source_group TEXT NOT NULL, pins BLOB NOT NULL, prepared BLOB NOT NULL);
 ALTER TABLE mls_rooms ADD COLUMN custody_required INTEGER NOT NULL DEFAULT 0 CHECK(custody_required IN (0,1));
 PRAGMA user_version=4; COMMIT;`)
	return e
}

func migrateSuccessorReservation(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v4-before-successor-reservation-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_reservations(intent TEXT PRIMARY KEY, room TEXT NOT NULL UNIQUE REFERENCES mls_rooms(room), reservation_id TEXT NOT NULL UNIQUE, context BLOB NOT NULL CHECK(length(context)<=4096));
 PRAGMA user_version=5; COMMIT;`)
	return e
}

func migrateSuccessorCustody(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v5-before-successor-custody-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_custody(intent TEXT PRIMARY KEY REFERENCES mls_successor_reservations(intent), declarations BLOB NOT NULL CHECK(length(declarations)<=1024));
 INSERT INTO mls_successor_custody SELECT intent, CAST('[]' AS BLOB) FROM mls_successor_reservations;
 PRAGMA user_version=6; COMMIT;`)
	return e
}

func migrateSuccessorHandshake(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v6-before-successor-handshake-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_handshake(intent TEXT PRIMARY KEY REFERENCES mls_successor_reservations(intent), group_id TEXT UNIQUE, transcript BLOB NOT NULL CHECK(length(transcript)<=196608));
 INSERT INTO mls_successor_handshake SELECT intent, NULL, CAST('[]' AS BLOB) FROM mls_successor_reservations;
 PRAGMA user_version=7; COMMIT;`)
	return e
}

func migrateSuccessorConfirmation(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v7-before-successor-confirmation-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_confirmation(intent TEXT PRIMARY KEY REFERENCES mls_successor_reservations(intent), transcript BLOB NOT NULL CHECK(length(transcript)<=16384));
 INSERT INTO mls_successor_confirmation SELECT intent, CAST('[]' AS BLOB) FROM mls_successor_reservations;
 PRAGMA user_version=8; COMMIT;`)
	return e
}

func migrateSuccessorLease(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v8-before-successor-lease-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_leases(intent TEXT PRIMARY KEY REFERENCES mls_successor_reservations(intent), approvals BLOB NOT NULL CHECK(length(approvals)<=512));
 INSERT INTO mls_successor_leases SELECT intent,CAST('[]' AS BLOB) FROM mls_successor_reservations;
 CREATE TABLE mls_successor_lease_events(intent TEXT NOT NULL REFERENCES mls_successor_leases(intent), seq INTEGER NOT NULL, device TEXT NOT NULL, client_id TEXT NOT NULL, message BLOB NOT NULL CHECK(length(message)<=8192), PRIMARY KEY(intent,seq), UNIQUE(intent,device,client_id));
 PRAGMA user_version=9; COMMIT;`)
	return e
}

func migrateSuccessorRetirement(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v9-before-successor-retirement-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_retirements(intent TEXT PRIMARY KEY REFERENCES mls_successor_leases(intent), request BLOB CHECK(request IS NULL OR length(request)<=256));
 INSERT INTO mls_successor_retirements SELECT intent,NULL FROM mls_successor_leases;
 PRAGMA user_version=10; COMMIT;`)
	return e
}

func migrateSuccessorEnrollment(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v10-before-successor-enrollment-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_enrollments(intent TEXT PRIMARY KEY REFERENCES mls_successor_leases(intent), approvals BLOB NOT NULL CHECK(length(approvals)<=512));
 INSERT INTO mls_successor_enrollments SELECT intent,CAST('[]' AS BLOB) FROM mls_successor_leases;
 CREATE TABLE mls_successor_enrolled_events(intent TEXT NOT NULL REFERENCES mls_successor_enrollments(intent), seq INTEGER NOT NULL, device TEXT NOT NULL, client_id TEXT NOT NULL, message BLOB NOT NULL CHECK(length(message)<=8192), PRIMARY KEY(intent,seq), UNIQUE(intent,device,client_id));
 PRAGMA user_version=11;COMMIT;`)
	return e
}

func migrateSuccessorClosure(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v11-before-successor-closure-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_closures(intent TEXT PRIMARY KEY REFERENCES mls_successor_enrollments(intent), request BLOB CHECK(request IS NULL OR length(request)<=256));
 INSERT INTO mls_successor_closures SELECT intent,NULL FROM mls_successor_enrollments;
 PRAGMA user_version=12;COMMIT;`)
	return e
}

// legacyRoom keeps plaintext rooms and rooms an archived MLS transport once
// claimed (rows in mls_rooms) strictly separate: such rooms stay denied to the
// plaintext API, exactly as before the freeze, instead of silently reappearing.
func (s *Store) legacyRoom(room string) error {
	var n int
	if e := s.db.QueryRow("SELECT count(*) FROM mls_rooms WHERE room=?", room).Scan(&n); e != nil {
		return e
	}
	if n != 0 {
		return ErrForbidden
	}
	return nil
}
func (s *Store) legacyMember(room, actor string) error {
	if e := s.legacyRoom(room); e != nil {
		return e
	}
	return s.member(room, actor)
}
