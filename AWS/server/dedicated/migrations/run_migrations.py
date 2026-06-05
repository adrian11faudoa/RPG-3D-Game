#!/usr/bin/env python3
"""
Veilborn — Database Migration Runner
Applies SQL migrations from /migrations/sql/ in order.
Tracks applied migrations in a 'schema_migrations' table.
"""
import argparse
import os
import sys
import psycopg2
import psycopg2.extras
from pathlib import Path
from datetime import datetime, timezone


def run_migrations(database_url: str, migrations_dir: str) -> None:
    print(f"Connecting to database...")
    try:
        conn = psycopg2.connect(database_url)
        conn.autocommit = False
    except Exception as e:
        print(f"ERROR: Cannot connect to database: {e}")
        sys.exit(1)

    cur = conn.cursor()

    # Create migrations tracking table if not exists
    cur.execute("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            id          SERIAL PRIMARY KEY,
            filename    TEXT NOT NULL UNIQUE,
            applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            checksum    TEXT
        )
    """)
    conn.commit()

    # Get already-applied migrations
    cur.execute("SELECT filename FROM schema_migrations ORDER BY filename")
    applied = {row[0] for row in cur.fetchall()}

    # Find pending migrations
    sql_dir = Path(migrations_dir)
    migration_files = sorted(
        f for f in sql_dir.glob("*.sql")
        if f.name not in applied
    )

    if not migration_files:
        print("No pending migrations.")
        cur.close()
        conn.close()
        return

    print(f"Applying {len(migration_files)} migration(s)...")

    for migration_file in migration_files:
        print(f"  → {migration_file.name}")
        sql = migration_file.read_text()
        import hashlib
        checksum = hashlib.sha256(sql.encode()).hexdigest()[:16]

        try:
            cur.execute(sql)
            cur.execute(
                "INSERT INTO schema_migrations (filename, checksum) VALUES (%s, %s)",
                (migration_file.name, checksum)
            )
            conn.commit()
            print(f"    ✓ Applied ({checksum})")
        except Exception as e:
            conn.rollback()
            print(f"    ✗ FAILED: {e}")
            cur.close()
            conn.close()
            sys.exit(1)

    print("All migrations applied successfully.")
    cur.close()
    conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run Veilborn DB migrations")
    parser.add_argument("--database-url", required=True)
    parser.add_argument("--migrations-dir", default="./sql")
    args = parser.parse_args()
    run_migrations(args.database_url, args.migrations_dir)
