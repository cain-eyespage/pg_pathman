/* ------------------------------------------------------------------------
 *
 * init.sql
 *		Creates config table and provides common utility functions
 *
 * Copyright (c) 2015-2016, Postgres Professional
 *
 * ------------------------------------------------------------------------
 */

/*
 * Pathman config
 *		partrel - regclass (relation type, stored as Oid)
 *		attname - partitioning key
 *		parttype - partitioning type:
 *			1 - HASH
 *			2 - RANGE
 *		range_interval - base interval for RANGE partitioning as string
 */
CREATE TABLE IF NOT EXISTS @extschema@.pathman_config (
	partrel			REGCLASS NOT NULL PRIMARY KEY,
	-- attname			TEXT NOT NULL,
	partkey			TEXT NOT NULL,
	parttype		INTEGER NOT NULL,
	range_interval	TEXT,

	CHECK (parttype IN (1, 2)) /* check for allowed part types */
);

/*
 * Optional parameters for partitioned tables.
 *		partrel - regclass (relation type, stored as Oid)
 *		enable_parent - add parent table to plan
 *		auto - enable automatic partition creation
 *		init_callback - cb to be executed on partition creation
 */
CREATE TABLE IF NOT EXISTS @extschema@.pathman_config_params (
	partrel			REGCLASS NOT NULL PRIMARY KEY,
	enable_parent	BOOLEAN NOT NULL DEFAULT FALSE,
	auto			BOOLEAN NOT NULL DEFAULT TRUE,
	init_callback	REGPROCEDURE NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX i_pathman_config_params
ON @extschema@.pathman_config_params(partrel);

GRANT SELECT, INSERT, UPDATE, DELETE
ON @extschema@.pathman_config, @extschema@.pathman_config_params
TO public;

/*
 * Check if current user can alter/drop specified relation
 */
CREATE OR REPLACE FUNCTION @extschema@.check_security_policy(relation regclass)
RETURNS BOOL AS 'pg_pathman', 'check_security_policy' LANGUAGE C STRICT;

/*
 * Row security policy to restrict partitioning operations to owner and
 * superusers only
 */
CREATE POLICY deny_modification ON @extschema@.pathman_config
FOR ALL USING (check_security_policy(partrel));

CREATE POLICY deny_modification ON @extschema@.pathman_config_params
FOR ALL USING (check_security_policy(partrel));

CREATE POLICY allow_select ON @extschema@.pathman_config FOR SELECT USING (true);

CREATE POLICY allow_select ON @extschema@.pathman_config_params FOR SELECT USING (true);

ALTER TABLE @extschema@.pathman_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE @extschema@.pathman_config_params ENABLE ROW LEVEL SECURITY;

/*
 * Invalidate relcache every time someone changes parameters config.
 */
CREATE OR REPLACE FUNCTION @extschema@.pathman_config_params_trigger_func()
RETURNS TRIGGER AS
$$
BEGIN
	IF TG_OP IN ('INSERT', 'UPDATE') THEN
		PERFORM @extschema@.invalidate_relcache(NEW.partrel);
	END IF;

	IF TG_OP IN ('UPDATE', 'DELETE') THEN
		PERFORM @extschema@.invalidate_relcache(OLD.partrel);
	END IF;

	IF TG_OP = 'DELETE' THEN
		RETURN OLD;
	ELSE
		RETURN NEW;
	END IF;
END
$$
LANGUAGE plpgsql;

CREATE TRIGGER pathman_config_params_trigger
BEFORE INSERT OR UPDATE OR DELETE ON @extschema@.pathman_config_params
FOR EACH ROW EXECUTE PROCEDURE @extschema@.pathman_config_params_trigger_func();

/*
 * Enable dump of config tables with pg_dump.
 */
SELECT pg_catalog.pg_extension_config_dump('@extschema@.pathman_config', '');
SELECT pg_catalog.pg_extension_config_dump('@extschema@.pathman_config_params', '');


CREATE OR REPLACE FUNCTION @extschema@.partitions_count(relation REGCLASS)
RETURNS INT AS
$$
BEGIN
	RETURN count(*) FROM pg_inherits WHERE inhparent = relation;
END
$$
LANGUAGE plpgsql STRICT;

/*
 * Add a row describing the optional parameter to pathman_config_params.
 */
CREATE OR REPLACE FUNCTION @extschema@.pathman_set_param(
	relation	REGCLASS,
	param		TEXT,
	value		ANYELEMENT)
RETURNS VOID AS
$$
BEGIN
	EXECUTE format('INSERT INTO @extschema@.pathman_config_params
					(partrel, %1$s) VALUES ($1, $2)
					ON CONFLICT (partrel) DO UPDATE SET %1$s = $2', param)
	USING relation, value;
END
$$
LANGUAGE plpgsql;

/*
 * Include\exclude parent relation in query plan.
 */
CREATE OR REPLACE FUNCTION @extschema@.set_enable_parent(
	relation	REGCLASS,
	value		BOOLEAN)
RETURNS VOID AS
$$
BEGIN
	PERFORM @extschema@.pathman_set_param(relation, 'enable_parent', value);
END
$$
LANGUAGE plpgsql STRICT;

/*
 * Enable\disable automatic partition creation.
 */
CREATE OR REPLACE FUNCTION @extschema@.set_auto(
	relation	REGCLASS,
	value		BOOLEAN)
RETURNS VOID AS
$$
BEGIN
	PERFORM @extschema@.pathman_set_param(relation, 'auto', value);
END
$$
LANGUAGE plpgsql STRICT;

/*
 * Set partition creation callback
 */
CREATE OR REPLACE FUNCTION @extschema@.set_init_callback(
	relation	REGCLASS,
	callback	REGPROC DEFAULT 0)
RETURNS VOID AS
$$
BEGIN
	PERFORM @extschema@.validate_on_partition_created_callback(callback);
	PERFORM @extschema@.pathman_set_param(relation, 'init_callback', callback);
END
$$
LANGUAGE plpgsql;

/*
 * Show all existing parents and partitions.
 */
CREATE OR REPLACE FUNCTION @extschema@.show_partition_list()
RETURNS TABLE (
	 parent		REGCLASS,
	 partition	REGCLASS,
	 parttype	INT4,
	 partattr	TEXT,
	 range_min	TEXT,
	 range_max	TEXT)
AS 'pg_pathman', 'show_partition_list_internal' LANGUAGE C STRICT;

/*
 * View for show_partition_list().
 */
CREATE OR REPLACE VIEW @extschema@.pathman_partition_list
AS SELECT * FROM @extschema@.show_partition_list();

GRANT SELECT ON @extschema@.pathman_partition_list TO PUBLIC;

/*
 * Show all existing concurrent partitioning tasks.
 */
CREATE OR REPLACE FUNCTION @extschema@.show_concurrent_part_tasks()
RETURNS TABLE (
	userid		REGROLE,
	pid			INT,
	dbid		OID,
	relid		REGCLASS,
	processed	INT,
	status		TEXT)
AS 'pg_pathman', 'show_concurrent_part_tasks_internal' LANGUAGE C STRICT;

/*
 * View for show_concurrent_part_tasks().
 */
CREATE OR REPLACE VIEW @extschema@.pathman_concurrent_part_tasks
AS SELECT * FROM @extschema@.show_concurrent_part_tasks();

GRANT SELECT ON @extschema@.pathman_concurrent_part_tasks TO PUBLIC;

/*
 * Partition table using ConcurrentPartWorker.
 */
CREATE OR REPLACE FUNCTION @extschema@.partition_table_concurrently(
	relation		REGCLASS,
	batch_size		INTEGER DEFAULT 1000,
	sleep_time		FLOAT8 DEFAULT 1.0)
RETURNS VOID AS 'pg_pathman', 'partition_table_concurrently'
LANGUAGE C STRICT;

/*
 * Stop concurrent partitioning task.
 */
CREATE OR REPLACE FUNCTION @extschema@.stop_concurrent_part_task(
	relation		REGCLASS)
RETURNS BOOL AS 'pg_pathman', 'stop_concurrent_part_task'
LANGUAGE C STRICT;


/*
 * Copy rows to partitions concurrently.
 */
CREATE OR REPLACE FUNCTION @extschema@._partition_data_concurrent(
	relation		REGCLASS,
	p_min			ANYELEMENT DEFAULT NULL::text,
	p_max			ANYELEMENT DEFAULT NULL::text,
	p_limit			INT DEFAULT NULL,
	OUT p_total		BIGINT)
AS
$$
DECLARE
	v_attr			TEXT;
	v_limit_clause	TEXT := '';
	v_where_clause	TEXT := '';
	ctids			TID[];

BEGIN
	SELECT attname INTO v_attr
	FROM @extschema@.pathman_config WHERE partrel = relation;

	p_total := 0;

	/* Format LIMIT clause if needed */
	IF NOT p_limit IS NULL THEN
		v_limit_clause := format('LIMIT %s', p_limit);
	END IF;

	/* Format WHERE clause if needed */
	IF NOT p_min IS NULL THEN
		v_where_clause := format('%1$s >= $1', v_attr);
	END IF;

	IF NOT p_max IS NULL THEN
		IF NOT p_min IS NULL THEN
			v_where_clause := v_where_clause || ' AND ';
		END IF;
		v_where_clause := v_where_clause || format('%1$s < $2', v_attr);
	END IF;

	IF v_where_clause != '' THEN
		v_where_clause := 'WHERE ' || v_where_clause;
	END IF;

	/* Lock rows and copy data */
	RAISE NOTICE 'Copying data to partitions...';
	EXECUTE format('SELECT array(SELECT ctid FROM ONLY %1$s %2$s %3$s FOR UPDATE NOWAIT)',
				   relation, v_where_clause, v_limit_clause)
	USING p_min, p_max
	INTO ctids;

	EXECUTE format('
		WITH data AS (
			DELETE FROM ONLY %1$s WHERE ctid = ANY($1) RETURNING *)
		INSERT INTO %1$s SELECT * FROM data',
		relation)
	USING ctids;

	/* Get number of inserted rows */
	GET DIAGNOSTICS p_total = ROW_COUNT;
	RETURN;
END
$$
LANGUAGE plpgsql
SET pg_pathman.enable_partitionfilter = on; /* ensures that PartitionFilter is ON */

/*
 * Old school way to distribute rows to partitions.
 */
CREATE OR REPLACE FUNCTION @extschema@.partition_data(
	parent_relid	REGCLASS,
	OUT p_total		BIGINT)
AS
$$
DECLARE
	relname		TEXT;
	rec			RECORD;
	cnt			BIGINT := 0;

BEGIN
	p_total := 0;

	/* Create partitions and copy rest of the data */
	EXECUTE format('WITH part_data AS (DELETE FROM ONLY %1$s RETURNING *)
					INSERT INTO %1$s SELECT * FROM part_data',
				   parent_relid::TEXT);

	/* Get number of inserted rows */
	GET DIAGNOSTICS p_total = ROW_COUNT;
	RETURN;
END
$$
LANGUAGE plpgsql STRICT
SET pg_pathman.enable_partitionfilter = on; /* ensures that PartitionFilter is ON */

/*
 * Disable pathman partitioning for specified relation.
 */
CREATE OR REPLACE FUNCTION @extschema@.disable_pathman_for(
	parent_relid	REGCLASS)
RETURNS VOID AS
$$
BEGIN
	PERFORM @extschema@.validate_relname(parent_relid);

	DELETE FROM @extschema@.pathman_config WHERE partrel = parent_relid;
	PERFORM @extschema@.drop_triggers(parent_relid);

	/* Notify backend about changes */
	PERFORM @extschema@.on_remove_partitions(parent_relid);
END
$$
LANGUAGE plpgsql STRICT;

/*
 * Validates relation name. It must be schema qualified.
 */
CREATE OR REPLACE FUNCTION @extschema@.validate_relname(
	cls		REGCLASS)
RETURNS TEXT AS
$$
DECLARE
	relname	TEXT;

BEGIN
	relname = @extschema@.get_schema_qualified_name(cls);

	IF relname IS NULL THEN
		RAISE EXCEPTION 'relation %s does not exist', cls;
	END IF;

	RETURN relname;
END
$$
LANGUAGE plpgsql;

/*
 * Aggregates several common relation checks before partitioning.
 * Suitable for every partitioning type.
 */
CREATE OR REPLACE FUNCTION @extschema@.common_relation_checks(
	relation		REGCLASS,
	p_attribute		TEXT)
RETURNS BOOLEAN AS
$$
DECLARE
	v_rec			RECORD;
	is_referenced	BOOLEAN;
	rel_persistence	CHAR;

BEGIN
	/* Ignore temporary tables */
	SELECT relpersistence FROM pg_catalog.pg_class
	WHERE oid = relation INTO rel_persistence;

	IF rel_persistence = 't'::CHAR THEN
		RAISE EXCEPTION 'temporary table "%" cannot be partitioned',
						relation::TEXT;
	END IF;

	IF EXISTS (SELECT * FROM @extschema@.pathman_config
			   WHERE partrel = relation) THEN
		RAISE EXCEPTION 'relation "%" has already been partitioned', relation;
	END IF;

	IF @extschema@.is_attribute_nullable(relation, p_attribute) THEN
		RAISE EXCEPTION 'partitioning key ''%'' must be NOT NULL', p_attribute;
	END IF;

	/* Check if there are foreign keys that reference the relation */
	FOR v_rec IN (SELECT * FROM pg_catalog.pg_constraint
				  WHERE confrelid = relation::REGCLASS::OID)
	LOOP
		is_referenced := TRUE;
		RAISE WARNING 'foreign key "%" references relation "%"',
				v_rec.conname, relation;
	END LOOP;

	IF is_referenced THEN
		RAISE EXCEPTION 'relation "%" is referenced from other relations', relation;
	END IF;

	RETURN TRUE;
END
$$
LANGUAGE plpgsql;

/*
 * Returns relname without quotes or something.
 */
CREATE OR REPLACE FUNCTION @extschema@.get_plain_schema_and_relname(
	cls				REGCLASS,
	OUT schema		TEXT,
	OUT relname		TEXT)
AS
$$
BEGIN
	SELECT pg_catalog.pg_class.relnamespace::regnamespace,
		   pg_catalog.pg_class.relname
	FROM pg_catalog.pg_class WHERE oid = cls::oid
	INTO schema, relname;
END
$$
LANGUAGE plpgsql STRICT;

/*
 * Returns the schema-qualified name of table.
 */
CREATE OR REPLACE FUNCTION @extschema@.get_schema_qualified_name(
	cls			REGCLASS,
	delimiter	TEXT DEFAULT '.',
	suffix		TEXT DEFAULT '')
RETURNS TEXT AS
$$
BEGIN
	RETURN (SELECT quote_ident(relnamespace::regnamespace::text) ||
				   delimiter ||
				   quote_ident(relname || suffix)
			FROM pg_catalog.pg_class
			WHERE oid = cls::oid);
END
$$
LANGUAGE plpgsql STRICT;

/*
 * Check if two relations have equal structures.
 */
CREATE OR REPLACE FUNCTION @extschema@.validate_relations_equality(
	relation1 OID, relation2 OID)
RETURNS BOOLEAN AS
$$
DECLARE
	rec	RECORD;

BEGIN
	FOR rec IN (
		WITH
			a1 AS (select * from pg_catalog.pg_attribute
				   where attrelid = relation1 and attnum > 0),
			a2 AS (select * from pg_catalog.pg_attribute
				   where attrelid = relation2 and attnum > 0)
		SELECT a1.attname name1, a2.attname name2, a1.atttypid type1, a2.atttypid type2
		FROM a1
		FULL JOIN a2 ON a1.attnum = a2.attnum
	)
	LOOP
		IF rec.name1 IS NULL OR rec.name2 IS NULL OR rec.name1 != rec.name2 THEN
			RETURN false;
		END IF;
	END LOOP;

	RETURN true;
END
$$
LANGUAGE plpgsql;

/*
 * DDL trigger that removes entry from pathman_config table.
 */
CREATE OR REPLACE FUNCTION @extschema@.pathman_ddl_trigger_func()
RETURNS event_trigger AS
$$
DECLARE
	obj				record;
	pg_class_oid	oid;
	relids			regclass[];
BEGIN
	pg_class_oid = 'pg_catalog.pg_class'::regclass;

	/* Find relids to remove from config */
	SELECT array_agg(cfg.partrel) INTO relids
	FROM pg_event_trigger_dropped_objects() AS events
	JOIN @extschema@.pathman_config AS cfg ON cfg.partrel::oid = events.objid
	WHERE events.classid = pg_class_oid;

	/* Cleanup pathman_config */
	DELETE FROM @extschema@.pathman_config WHERE partrel = ANY(relids);

	/* Cleanup params table too */
	DELETE FROM @extschema@.pathman_config_params WHERE partrel = ANY(relids);
END
$$
LANGUAGE plpgsql;

/*
 * Drop triggers.
 */
CREATE OR REPLACE FUNCTION @extschema@.drop_triggers(
	parent_relid	REGCLASS)
RETURNS VOID AS
$$
BEGIN
	EXECUTE format('DROP FUNCTION IF EXISTS %s() CASCADE',
				   @extschema@.build_update_trigger_func_name(parent_relid));
END
$$ LANGUAGE plpgsql STRICT;

/*
 * Drop partitions. If delete_data set to TRUE, partitions
 * will be dropped with all the data.
 */
CREATE OR REPLACE FUNCTION @extschema@.drop_partitions(
	parent_relid	REGCLASS,
	delete_data		BOOLEAN DEFAULT FALSE)
RETURNS INTEGER AS
$$
DECLARE
	v_rec			RECORD;
	v_rows			BIGINT;
	v_part_count	INTEGER := 0;
	conf_num_del	INTEGER;
	v_relkind		CHAR;

BEGIN
	PERFORM @extschema@.validate_relname(parent_relid);

	/* Drop trigger first */
	PERFORM @extschema@.drop_triggers(parent_relid);

	WITH config_num_deleted AS (DELETE FROM @extschema@.pathman_config
								WHERE partrel = parent_relid
								RETURNING *)
	SELECT count(*) from config_num_deleted INTO conf_num_del;

	DELETE FROM @extschema@.pathman_config_params WHERE partrel = parent_relid;

	IF conf_num_del = 0 THEN
		RAISE EXCEPTION 'relation "%" has no partitions', parent_relid::TEXT;
	END IF;

	FOR v_rec IN (SELECT inhrelid::REGCLASS AS tbl
				  FROM pg_catalog.pg_inherits
				  WHERE inhparent::regclass = parent_relid
				  ORDER BY inhrelid ASC)
	LOOP
		IF NOT delete_data THEN
			EXECUTE format('INSERT INTO %s SELECT * FROM %s',
							parent_relid::TEXT,
							v_rec.tbl::TEXT);
			GET DIAGNOSTICS v_rows = ROW_COUNT;

			/* Show number of copied rows */
			RAISE NOTICE '% rows copied from %', v_rows, v_rec.tbl::TEXT;
		END IF;

		SELECT relkind FROM pg_catalog.pg_class
		WHERE oid = v_rec.tbl
		INTO v_relkind;

		/*
		 * Determine the kind of child relation. It can be either regular
		 * table (r) or foreign table (f). Depending on relkind we use
		 * DROP TABLE or DROP FOREIGN TABLE.
		 */
		IF v_relkind = 'f' THEN
			EXECUTE format('DROP FOREIGN TABLE %s', v_rec.tbl::TEXT);
		ELSE
			EXECUTE format('DROP TABLE %s', v_rec.tbl::TEXT);
		END IF;

		v_part_count := v_part_count + 1;
	END LOOP;

	/* Notify backend about changes */
	PERFORM @extschema@.on_remove_partitions(parent_relid);

	RETURN v_part_count;
END
$$ LANGUAGE plpgsql
SET pg_pathman.enable_partitionfilter = off; /* ensures that PartitionFilter is OFF */


/*
 * Copy all of parent's foreign keys.
 */
CREATE OR REPLACE FUNCTION @extschema@.copy_foreign_keys(
	parent_relid	REGCLASS,
	partition		REGCLASS)
RETURNS VOID AS
$$
DECLARE
	rec		RECORD;

BEGIN
	PERFORM @extschema@.validate_relname(parent_relid);
	PERFORM @extschema@.validate_relname(partition);

	FOR rec IN (SELECT oid as conid FROM pg_catalog.pg_constraint
				WHERE conrelid = parent_relid AND contype = 'f')
	LOOP
		EXECUTE format('ALTER TABLE %s ADD %s',
					   partition::TEXT,
					   pg_catalog.pg_get_constraintdef(rec.conid));
	END LOOP;
END
$$ LANGUAGE plpgsql STRICT;


/*
 * Create DDL trigger to call pathman_ddl_trigger_func().
 */
CREATE EVENT TRIGGER pathman_ddl_trigger
ON sql_drop
EXECUTE PROCEDURE @extschema@.pathman_ddl_trigger_func();



CREATE OR REPLACE FUNCTION @extschema@.on_create_partitions(
	relid	REGCLASS)
RETURNS VOID AS 'pg_pathman', 'on_partitions_created'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.on_update_partitions(
	relid	REGCLASS)
RETURNS VOID AS 'pg_pathman', 'on_partitions_updated'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.on_remove_partitions(
	relid	REGCLASS)
RETURNS VOID AS 'pg_pathman', 'on_partitions_removed'
LANGUAGE C STRICT;


/*
 * Get parent of pg_pathman's partition.
 */
CREATE OR REPLACE FUNCTION @extschema@.get_parent_of_partition(REGCLASS)
RETURNS REGCLASS AS 'pg_pathman', 'get_parent_of_partition_pl'
LANGUAGE C STRICT;

/*
 * Extract basic type of a domain.
 */
CREATE OR REPLACE FUNCTION @extschema@.get_base_type(REGTYPE)
RETURNS REGTYPE AS 'pg_pathman', 'get_base_type_pl'
LANGUAGE C STRICT;

/*
 * Returns attribute type name for relation.
 */
CREATE OR REPLACE FUNCTION @extschema@.get_attribute_type(
	REGCLASS, TEXT)
RETURNS REGTYPE AS 'pg_pathman', 'get_attribute_type_pl'
LANGUAGE C STRICT;

/*
 * Return tablespace name for specified relation.
 */
CREATE OR REPLACE FUNCTION @extschema@.get_rel_tablespace_name(REGCLASS)
RETURNS TEXT AS 'pg_pathman', 'get_rel_tablespace_name'
LANGUAGE C STRICT;


/*
 * Checks if attribute is nullable
 */
CREATE OR REPLACE FUNCTION @extschema@.is_attribute_nullable(
	REGCLASS, TEXT)
RETURNS BOOLEAN AS 'pg_pathman', 'is_attribute_nullable'
LANGUAGE C STRICT;

/*
 * Check if regclass is date or timestamp.
 */
CREATE OR REPLACE FUNCTION @extschema@.is_date_type(
	typid	REGTYPE)
RETURNS BOOLEAN AS 'pg_pathman', 'is_date_type'
LANGUAGE C STRICT;


/*
 * Build check constraint name for a specified relation's column.
 */
CREATE OR REPLACE FUNCTION @extschema@.build_check_constraint_name(
	REGCLASS, INT2)
RETURNS TEXT AS 'pg_pathman', 'build_check_constraint_name_attnum'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.build_check_constraint_name(
	REGCLASS, TEXT)
RETURNS TEXT AS 'pg_pathman', 'build_check_constraint_name_attname'
LANGUAGE C STRICT;

/*
 * Build update trigger and its underlying function's names.
 */
CREATE OR REPLACE FUNCTION @extschema@.build_update_trigger_name(
	REGCLASS)
RETURNS TEXT AS 'pg_pathman', 'build_update_trigger_name'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.build_update_trigger_func_name(
	REGCLASS)
RETURNS TEXT AS 'pg_pathman', 'build_update_trigger_func_name'
LANGUAGE C STRICT;


/*
 * Attach a previously partitioned table.
 */
CREATE OR REPLACE FUNCTION @extschema@.add_to_pathman_config(
	parent_relid	REGCLASS,
	attname			TEXT,
	range_interval	TEXT DEFAULT NULL)
RETURNS BOOLEAN AS 'pg_pathman', 'add_to_pathman_config'
LANGUAGE C;

CREATE OR REPLACE FUNCTION @extschema@.invalidate_relcache(relid OID)
RETURNS VOID AS 'pg_pathman'
LANGUAGE C STRICT;


/*
 * Lock partitioned relation to restrict concurrent
 * modification of partitioning scheme.
 */
 CREATE OR REPLACE FUNCTION @extschema@.lock_partitioned_relation(
	 REGCLASS)
 RETURNS VOID AS 'pg_pathman', 'lock_partitioned_relation'
 LANGUAGE C STRICT;

/*
 * Lock relation to restrict concurrent modification of data.
 */
 CREATE OR REPLACE FUNCTION @extschema@.prevent_relation_modification(
	 REGCLASS)
 RETURNS VOID AS 'pg_pathman', 'prevent_relation_modification'
 LANGUAGE C STRICT;


/*
 * DEBUG: Place this inside some plpgsql fuction and set breakpoint.
 */
CREATE OR REPLACE FUNCTION @extschema@.debug_capture()
RETURNS VOID AS 'pg_pathman', 'debug_capture'
LANGUAGE C STRICT;

/*
 * Checks that callback function meets specific requirements. Particularly it
 * must have the only JSONB argument and VOID return type.
 */
CREATE OR REPLACE FUNCTION @extschema@.validate_on_partition_created_callback(
	callback		REGPROC)
RETURNS VOID AS 'pg_pathman', 'validate_on_part_init_callback_pl'
LANGUAGE C STRICT;


/*
 * Invoke init_callback on RANGE partition.
 */
CREATE OR REPLACE FUNCTION @extschema@.invoke_on_partition_created_callback(
	parent_relid	REGCLASS,
	partition		REGCLASS,
	init_callback	REGPROCEDURE,
	start_value		ANYELEMENT,
	end_value		ANYELEMENT)
RETURNS VOID AS 'pg_pathman', 'invoke_on_partition_created_callback'
LANGUAGE C;

/*
 * Invoke init_callback on HASH partition.
 */
CREATE OR REPLACE FUNCTION @extschema@.invoke_on_partition_created_callback(
	parent_relid	REGCLASS,
	partition		REGCLASS,
	init_callback	REGPROCEDURE)
RETURNS VOID AS 'pg_pathman', 'invoke_on_partition_created_callback'
LANGUAGE C;

CREATE OR REPLACE FUNCTION @extschema@.validate_partkey(
	relid			REGCLASS,
	key 			TEXT)
RETURNS VOID AS 'pg_pathman', 'validate_partkey'
LANGUAGE C;
