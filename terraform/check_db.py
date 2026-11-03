import os
import psycopg2

try:
    conn = psycopg2.connect(os.environ["DSN"])
    cur = conn.cursor()
    cur.execute(
        "SELECT table_schema, table_name FROM information_schema.tables "
        "WHERE table_schema NOT IN ('pg_catalog', 'information_schema')"
    )
    print("TABLES FOUND:", cur.fetchall())
    conn.close()
except Exception as e:
    print("ERROR:", e)
