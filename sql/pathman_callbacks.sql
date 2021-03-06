\set VERBOSITY terse

CREATE EXTENSION pg_pathman;
CREATE SCHEMA callbacks;

/* Check callbacks */

CREATE OR REPLACE FUNCTION callbacks.abc_on_part_created_callback(
	args JSONB)
RETURNS VOID AS $$
BEGIN
	RAISE WARNING 'callback arg: %', args::TEXT;
END
$$ language plpgsql;


/* set callback to be called on RANGE partitions */
CREATE TABLE callbacks.abc(a serial, b int);
SELECT create_range_partitions('callbacks.abc', 'a', 1, 100, 2);

SELECT set_init_callback('callbacks.abc',
						 'callbacks.abc_on_part_created_callback');

INSERT INTO callbacks.abc VALUES (123, 1);
INSERT INTO callbacks.abc VALUES (223, 1); /* show warning */

SELECT set_spawn_using_bgw('callbacks.abc', true);
SELECT get_number_of_partitions('callbacks.abc');
INSERT INTO callbacks.abc VALUES (323, 1);
SELECT get_number_of_partitions('callbacks.abc'); /* +1 partition (created by BGW) */
SELECT set_spawn_using_bgw('callbacks.abc', false);


SELECT append_range_partition('callbacks.abc');
SELECT prepend_range_partition('callbacks.abc');
SELECT add_range_partition('callbacks.abc', 501, 602);

SELECT drop_partitions('callbacks.abc');


/* set callback to be called on HASH partitions */
SELECT set_init_callback('callbacks.abc',
						 'callbacks.abc_on_part_created_callback');
SELECT create_hash_partitions('callbacks.abc', 'a', 5);

DROP TABLE callbacks.abc CASCADE;

/* create table in public schema */
CREATE TABLE abc(a serial, b int);
SELECT set_init_callback('abc',
						 'callbacks.abc_on_part_created_callback');
SELECT create_range_partitions('abc', 'a', 1, 100, 2);

DROP TABLE abc CASCADE;

DROP SCHEMA callbacks CASCADE;
DROP EXTENSION pg_pathman CASCADE;
