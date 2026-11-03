import os
import psycopg2

SOURCE_DDL = """
CREATE TABLE IF NOT EXISTS legacy_users (
    id           INTEGER PRIMARY KEY,
    full_name    TEXT,
    phone_number TEXT,
    email        TEXT
);
"""

TARGET_DDL = """
CREATE TABLE IF NOT EXISTS new_users (
    id         INTEGER PRIMARY KEY,
    first_name TEXT NOT NULL,
    last_name  TEXT,
    phone      TEXT,
    email      TEXT NOT NULL
);
"""

SAMPLE = """
INSERT INTO legacy_users (id, full_name, phone_number, email) VALUES
    (1, 'Ada Lovelace', '(555) 123-4567', 'ada@example.com'),
    (2, 'Alan Turing', '555.987.6543', 'alan@example.com'),
    (3, '', '000', 'bad-row-no-name@example.com')
ON CONFLICT (id) DO NOTHING;
"""


def run(env_var, ddl, seed=None):
    with psycopg2.connect(os.environ[env_var]) as conn, conn.cursor() as cur:
        cur.execute(ddl)
        if seed:
            cur.execute(seed)
    conn.close()
    print(f"{env_var}: OK")


if __name__ == "__main__":
    run("SOURCE_DB_DSN", SOURCE_DDL, SAMPLE if os.getenv("SEED") == "1" else None)
    run("TARGET_DB_DSN", TARGET_DDL)
