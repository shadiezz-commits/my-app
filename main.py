import os 
import json 
import logging 
import psycopg2 
from psycopg2.extras import execute_values 
import re 

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# Configuration
BATCH_SIZE = 100
DEAD_LETTER_FILE = 'dead_letter.json'

def get_db_connection(dsn_env_var):
    return psycopg2.connect(os.getenv(dsn_env_var))

def transform_record(record):
    try:
        rec_id, full_name, phone, email = record
        if rec_id is None:
            raise ValueError('missing id')

        if not full_name or not str(full_name).strip():
            raise ValueError('missing full_name')

        if not email or '@' not in str(email):
            raise ValueError('invalid email')
            
        name_parts = str(full_name).strip().split(None, 1)
        first_name = name_parts[0]
        last_name = name_parts[1] if len(name_parts) > 1 else ''
        
        sanitized_phone = re.sub(r'\D', '', str(phone)) if phone else ''
        
        return (rec_id, first_name, last_name, sanitized_phone, email)
        
    except Exception as e:
        raise ValueError(f"Transformation failed: {e}")

def log_dead_letter(record, error_msg):
    """The 'a' means append mode.
        Append mode means:
        - Create the file if it doesn't exist.
        - Add new content at the end.
        - Don't delete existing content.
        with is a context manager. It automatically closes the file when the block finishes."""
    error_entry = {"record": record, "error": str(error_msg)}
    try:
        with open(DEAD_LETTER_FILE, 'a') as f:
            """Converts a Python dictionary into JSON text."""
            f.write(json.dumps(error_entry, default=str) + '\n')
    except Exception as e:
        logging.error(f"Failed to write to dead letter file: {e}")

def run_migration():
    source_conn = None
    target_conn = None
    
    try:
        source_conn = get_db_connection('SOURCE_DB_DSN')
        target_conn = get_db_connection('TARGET_DB_DSN')
        
        source_cursor = source_conn.cursor(name="legacy_users_cur")
        target_cursor = target_conn.cursor()
        
        source_cursor.execute("SELECT id, full_name, phone_number, email FROM legacy_users;")
        
        while True:
            records = source_cursor.fetchmany(BATCH_SIZE)
            if not records:
                break 
            
            valid_records = []
            for rec in records:
                try:
                    transformed = transform_record(rec)
                    valid_records.append(transformed)
                except Exception as e:
                    logging.warning(f"Record {rec[0]} failed validation. Sending to dead-letter.")
                    log_dead_letter(rec, e)
            
            if valid_records:
                insert_query = """
                    INSERT INTO new_users (id, first_name, last_name, phone, email)
                    VALUES %s
                    ON CONFLICT (id) DO UPDATE SET
                        first_name = EXCLUDED.first_name,
                        last_name = EXCLUDED.last_name,
                        phone = EXCLUDED.phone,
                        email = EXCLUDED.email;
                """
                try:
                    execute_values(target_cursor, insert_query, valid_records)
                    target_conn.commit()
                except Exception as batch_err:
                    target_conn.rollback()
                    logging.warning(f'Batch failed ({batch_err}); retrying row by row.')
                    for row in valid_records:
                        try:
                            execute_values(target_cursor, insert_query, [row])
                            target_conn.commit()
                        except Exception as row_err:
                            target_conn.rollback()
                            log_dead_letter(row, row_err)
                
            logging.info(f"Processed batch of {len(records)} records.")
            
    except Exception as e:
        logging.error(f"Migration aborted due to fatal error: {e}")
        raise
    finally:
        if source_conn: source_conn.close()
        if target_conn: target_conn.close()
        logging.info("Database connections closed.")

if __name__ == "__main__":
    logging.info("Starting ETL Pipeline...")
    try:
        run_migration()
    except Exception:
        raise SystemExit(1)
    logging.info("ETL Pipeline finished.")
