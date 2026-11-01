--
-- PostgreSQL database dump
--

-- Dumped from database version 11.11
-- Dumped by pg_dump version 11.11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = off;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET escape_string_warning = off;
SET row_security = off;

--
-- Name: test; Type: SCHEMA; Schema: -; Owner: SynologyPhotos
--

CREATE SCHEMA test;


ALTER SCHEMA test OWNER TO "SynologyPhotos";

--
-- Name: analyze_temp_table_for_delete_task(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.analyze_temp_table_for_delete_task(task_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  temp_table_name TEXT;
BEGIN
  temp_table_name := 'temp_table_for_delete_task_' || task_id;
  EXECUTE 'ANALYZE ' || temp_table_name;
END;
$$;


ALTER FUNCTION public.analyze_temp_table_for_delete_task(task_id integer) OWNER TO "SynologyPhotos";

--
-- Name: any_user_need_migrate_similar_hash(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.any_user_need_migrate_similar_hash() RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE COST 1
    AS $$
BEGIN
    RETURN EXISTS (
      SELECT 1 FROM public.user_info
      WHERE user_info.config ->> 'enable_similar' = 'true'
      AND user_info.enable = 'true'
      AND NOT EXISTS (
        SELECT 1 FROM public.user_flag
        WHERE user_info.id = user_flag.id_user
        AND user_flag.flag = 'similar_hash_migration_done'
        AND (user_flag.value = 'true' OR user_flag.value = 'error')
      )
    );
END
$$;


ALTER FUNCTION public.any_user_need_migrate_similar_hash() OWNER TO "SynologyPhotos";

--
-- Name: concept_album_list(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.concept_album_list(user_id integer) RETURNS TABLE(id_concept integer, stem text, parent integer[], display_threshold smallint, sort_index integer, item_count bigint, default_cover_id_unit integer[], custom_cover_id_unit integer, visibility_status smallint)
    LANGUAGE plpgsql
    AS $$ BEGIN RETURN QUERY
  WITH main AS(
    SELECT concept.id AS id_concept,
      (
        SELECT caa.custom_cover_id_unit
        FROM concept_album_additional caa
        WHERE concept.id = caa.id_concept
          AND caa.id_user = user_id
      ) as custom_cover_unit_id,
      (
        SELECT caa.item_count
        FROM concept_album_additional caa
        WHERE concept.id = caa.id_concept
          AND caa.id_user = user_id
      ) as item_count,
      ARRAY(
        (
          SELECT m.id_unit
          FROM many_unit_has_many_concept m
            JOIN unit ON unit.id = m.id_unit
          WHERE m.id_user = user_id
            AND concept.id = m.id_concept
            AND unit.is_major = true
          ORDER BY m.confidence
          LIMIT 5
        )
      ) as default_cover_id_unit,
      (
        SELECT caa.visibility_status
        FROM concept_album_additional caa
        WHERE concept.id = caa.id_concept
          AND caa.id_user = user_id
      ) as visibility_status
    FROM concept
    WHERE concept.hidden = false
    ORDER BY concept.sort_index
  )
  SELECT main.id_concept,
    concept.stem,
    concept.parent,
    concept.display_threshold,
    concept.sort_index,
    main.item_count,
    main.default_cover_id_unit,
    CASE
      WHEN (
        EXISTS(
          SELECT 1
          FROM many_unit_has_many_concept m
          WHERE m.id_unit = main.custom_cover_unit_id
            AND m.id_concept = main.id_concept
        )
      ) THEN main.custom_cover_unit_id
      ELSE NULL
    END as custom_cover_id_unit,
    main.visibility_status
  FROM main
    JOIN concept on concept.id = main.id_concept;
END;
$$;


ALTER FUNCTION public.concept_album_list(user_id integer) OWNER TO "SynologyPhotos";

--
-- Name: copy_version_time_to_version_time_by_user_func(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.copy_version_time_to_version_time_by_user_func(id_user integer) RETURNS void
    LANGUAGE plpgsql STRICT COST 1
    AS $$
DECLARE
  version_time_table text := 'public.version_time';
  new_version_time_table text;
  trigger_name text;
  max_version bigint;
  has_data_below_max_version INTEGER;
  id_user_bucket INTEGER;
  migrated_version_time_count INTEGER;
  migrated_version_table text;
  migrated_version_table_name text;
  has_migrated_version_table boolean;
BEGIN
  id_user_bucket := CASE WHEN id_user = 0 THEN 0 ELSE (id_user - 1) % 13 + 1 END;
  new_version_time_table = 'public.version_time_' || id_user_bucket;
  migrated_version_table = 'public.version_time_' || id_user;
  migrated_version_table_name = 'version_time_' || id_user;
  trigger_name = 'delete_expired_version_time_' || id_user_bucket || '_data_trigger';
  has_migrated_version_table := EXISTS (
      SELECT 1
      FROM information_schema.tables
      WHERE table_schema = 'public'
      AND table_name = migrated_version_table_name);
  IF NOT has_migrated_version_table THEN
    EXECUTE format('DROP TRIGGER IF EXISTS %s ON %s CASCADE', trigger_name, new_version_time_table);
    EXECUTE format('INSERT INTO %s (version, modified_time) SELECT version, modified_time FROM %s ON CONFLICT (version, modified_time) DO NOTHING',
      new_version_time_table, version_time_table);
    EXECUTE format('CREATE TRIGGER %s BEFORE INSERT ON %s FOR EACH ROW EXECUTE PROCEDURE public.delete_expired_version_time_data_func()',
        trigger_name, new_version_time_table);
  ELSE
    EXECUTE format('DROP TRIGGER IF EXISTS %s ON %s CASCADE', trigger_name, new_version_time_table);
    EXECUTE format('INSERT INTO %s SELECT * FROM %s ON CONFLICT (version, modified_time) DO NOTHING', new_version_time_table, migrated_version_table);
    -- check if there are already data under max_version of version_time in the new_version_time_table
    SELECT COALESCE(MAX(version), 0) FROM public.version_time INTO max_version;
    EXECUTE format('SELECT 1 FROM %s WHERE version <= %L LIMIT 1', new_version_time_table, max_version) INTO has_data_below_max_version;
    EXECUTE format('SELECT COUNT(*) FROM %s', migrated_version_table) INTO migrated_version_time_count;
    IF migrated_version_time_count < 100000 AND has_data_below_max_version IS NULL THEN
      EXECUTE format('INSERT INTO %s (version, modified_time) SELECT version, modified_time FROM %s ON CONFLICT (version, modified_time) DO NOTHING',
        new_version_time_table, version_time_table);
    END IF;
    EXECUTE format('CREATE TRIGGER %s BEFORE INSERT ON %s FOR EACH ROW EXECUTE PROCEDURE public.delete_expired_version_time_data_func()',
        trigger_name, new_version_time_table);
    IF id_user > 13 THEN
      EXECUTE format('DROP TABLE IF EXISTS %s CASCADE', migrated_version_table);
    END IF;
  END IF;
END;
$$;


ALTER FUNCTION public.copy_version_time_to_version_time_by_user_func(id_user integer) OWNER TO "SynologyPhotos";

--
-- Name: create_face_migration_manual_map_table_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.create_face_migration_manual_map_table_func() RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
BEGIN
  CREATE TABLE IF NOT EXISTS face_migration_manual_map
  AS
    SELECT
      id,
      id_user,
      false AS visited FROM face_migration WHERE is_manual = true;
  IF NOT EXISTS (
    SELECT
      constraint_name
    FROM
      information_schema.table_constraints
    WHERE
      table_name = 'face_migration_manual_map' AND constraint_type = 'PRIMARY KEY'
  ) THEN
    ALTER TABLE face_migration_manual_map ADD PRIMARY KEY (id);
  END IF;
END
$$;


ALTER FUNCTION public.create_face_migration_manual_map_table_func() OWNER TO "SynologyPhotos";

--
-- Name: create_person_migration_migration_tables_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.create_person_migration_migration_tables_func() RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  production_tables CONSTANT TEXT[] := ARRAY['face', 'person_group', 'cluster', 'person'];
  table_name TEXT;
BEGIN
  FOR table_name IN SELECT unnest(production_tables) LOOP
    EXECUTE format('CREATE TABLE IF NOT EXISTS %s_migration (LIKE %s INCLUDING ALL)', table_name, table_name);
    EXECUTE format('TRUNCATE %s_migration CASCADE', table_name);
  END LOOP;
  PERFORM public.redefine_migration_constraint_func(production_tables);
  PERFORM public.create_production_index_mapping_func(production_tables);
  DROP TRIGGER IF EXISTS face_update_unit_version_trigger ON public.face_migration CASCADE;
  CREATE TRIGGER face_update_unit_version_trigger
    AFTER UPDATE
    ON public.face_migration
    FOR EACH ROW
    EXECUTE PROCEDURE public.face_update_unit_version_func();
END
$$;


ALTER FUNCTION public.create_person_migration_migration_tables_func() OWNER TO "SynologyPhotos";

--
-- Name: create_production_index_mapping_func(text[]); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.create_production_index_mapping_func(production_tables text[]) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  table_name TEXT;
BEGIN
  CREATE TABLE IF NOT EXISTS production_table_index_mapping (
      tb_name TEXT,
      index_name TEXT,
      index_def TEXT
  );
  TRUNCATE production_table_index_mapping;
  FOR table_name IN SELECT unnest(production_tables) LOOP
    INSERT INTO production_table_index_mapping (tb_name, index_name, index_def)
      SELECT tablename, indexname,
              split_part(indexdef, 'USING ', 2)
      FROM pg_indexes
      WHERE tablename = table_name;
  END LOOP;
END
$$;


ALTER FUNCTION public.create_production_index_mapping_func(production_tables text[]) OWNER TO "SynologyPhotos";

--
-- Name: create_read_only_trigger_func(text); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.create_read_only_trigger_func(table_name text) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
BEGIN
  EXECUTE format('CREATE TRIGGER read_only_trigger
  BEFORE INSERT OR UPDATE ON %I
  FOR EACH STATEMENT
  EXECUTE PROCEDURE public.read_only_table()', table_name);
END;
$$;


ALTER FUNCTION public.create_read_only_trigger_func(table_name text) OWNER TO "SynologyPhotos";

--
-- Name: create_temp_table_for_delete_task(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.create_temp_table_for_delete_task(task_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  temp_table_name TEXT;
BEGIN
  temp_table_name := 'temp_table_for_delete_task_' || task_id;
  EXECUTE 'CREATE TABLE ' || temp_table_name || ' (id INTEGER)';
END;
$$;


ALTER FUNCTION public.create_temp_table_for_delete_task(task_id integer) OWNER TO "SynologyPhotos";

--
-- Name: create_user_event_history_table_by_id_user_func(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.create_user_event_history_table_by_id_user_func(id_user integer) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  id_user_bucket INT;
  user_event_history_table text;
  user_event_history_table_name text;
BEGIN
  id_user_bucket := CASE WHEN id_user = 0 THEN 0 ELSE (id_user - 1) % 13 + 1 END;
  user_event_history_table = 'public.user_event_history_' || id_user_bucket;
  user_event_history_table_name = 'user_event_history_' || id_user_bucket;
  IF EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
    AND table_name = user_event_history_table_name
  ) THEN
    RETURN;
  END IF;
  EXECUTE format('CREATE TABLE %s (
    version BIGINT PRIMARY KEY,
    id_user INTEGER NOT NULL,
    target_type SMALLINT NOT NULL,
    target_id INTEGER[] NOT NULL,
    target_id_user INTEGER NOT NULL,
    trigger_id_user INTEGER,
    event_type TEXT NOT NULL,
    event_detail JSON)', user_event_history_table
  );
  EXECUTE format('CREATE INDEX IF NOT EXISTS user_event_history_%s_version_id_user_idx ON %s (id_user, version);', id_user_bucket, user_event_history_table);
END
$$;


ALTER FUNCTION public.create_user_event_history_table_by_id_user_func(id_user integer) OWNER TO "SynologyPhotos";

--
-- Name: create_version_related_table_trigger_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.create_version_related_table_trigger_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- take care, version_time table should be created before user_event_history table
  PERFORM public.create_version_time_by_id_user_func(NEW.id);
  PERFORM public.create_user_event_history_table_by_id_user_func(NEW.id);
  RETURN NEW;
END
$$;


ALTER FUNCTION public.create_version_related_table_trigger_func() OWNER TO "SynologyPhotos";

--
-- Name: create_version_time_by_id_user_func(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.create_version_time_by_id_user_func(id_user integer) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  new_version_time_table text;
  new_version_time_table_name text;
  trigger_name text;
  pk_name text;
  idx_name text;
  new_sequence_name text;
  id_user_bucket integer;
BEGIN
  id_user_bucket := CASE WHEN id_user = 0 THEN 0 ELSE (id_user - 1) % 13 + 1 END;
  new_version_time_table = 'public.version_time_' || id_user_bucket;
  new_version_time_table_name = 'version_time_' || id_user_bucket;
  pk_name = 'version_id_' || id_user_bucket || '_primary';
  idx_name = 'version_time_' || id_user_bucket || '_idx';
  new_sequence_name = 'public.version_time_' || id_user_bucket || '_version_seq';
  trigger_name = 'delete_expired_version_time_' || id_user_bucket || '_data_trigger';
  -- check if the sequence and table already exists
  RAISE NOTICE 'Checking if sequence % and table % exist', new_sequence_name, new_version_time_table;
  IF EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
    AND table_name = new_version_time_table_name
  ) THEN
    RETURN;
  END IF;
  EXECUTE format('CREATE SEQUENCE %s START WITH 1', new_sequence_name);
  EXECUTE format('CREATE TABLE %s (version BIGINT NOT NULL DEFAULT nextval(''%s''), modified_time BIGINT NOT NULL)',
    new_version_time_table, new_sequence_name, pk_name);
  EXECUTE format('CREATE UNIQUE INDEX %s ON %s USING btree (version, modified_time ASC NULLS LAST)', idx_name, new_version_time_table);
  EXECUTE format('CREATE TRIGGER %s BEFORE INSERT ON %s FOR EACH ROW EXECUTE PROCEDURE public.delete_expired_version_time_data_func()',
    trigger_name, new_version_time_table);
END;
$$;


ALTER FUNCTION public.create_version_time_by_id_user_func(id_user integer) OWNER TO "SynologyPhotos";

--
-- Name: create_version_time_by_id_user_trigger_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.create_version_time_by_id_user_trigger_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  id_user integer := NEW.id;
  new_version_time_table text;
  new_version_time_table_name text;
  trigger_name text;
  pk_name text;
  idx_name text;
  new_sequence_name text;
  id_user_bucket integer;
BEGIN
  id_user_bucket := CASE WHEN id_user = 0 THEN 0 ELSE (id_user - 1) % 13 + 1 END;
  new_version_time_table = 'public.version_time_' || id_user_bucket;
  new_version_time_table_name = 'version_time_' || id_user_bucket;
  pk_name = 'version_id_' || id_user_bucket || '_primary';
  idx_name = 'version_time_' || id_user_bucket || '_idx';
  new_sequence_name = 'public.version_time_' || id_user_bucket || '_version_seq';
  trigger_name = 'delete_expired_version_time_' || id_user_bucket || '_data_trigger';
  -- check if the sequence and table already exists
  RAISE NOTICE 'Checking if sequence % and table % exist', new_sequence_name, new_version_time_table;
  IF EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
    AND table_name = new_version_time_table_name
  ) THEN
    RETURN NEW;
  END IF;
  EXECUTE format('CREATE SEQUENCE %s START WITH 1', new_sequence_name);
  EXECUTE format('CREATE TABLE %s (version BIGINT NOT NULL DEFAULT nextval(''%s''), modified_time BIGINT NOT NULL, CONSTRAINT %s PRIMARY KEY (version))',
    new_version_time_table, new_sequence_name, pk_name);
  EXECUTE format('CREATE INDEX %s ON %s USING btree (modified_time ASC NULLS LAST)', idx_name, new_version_time_table);
  EXECUTE format('CREATE TRIGGER %s BEFORE INSERT ON %s FOR EACH ROW EXECUTE PROCEDURE public.delete_expired_version_time_data_func()',
    trigger_name, new_version_time_table);
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.create_version_time_by_id_user_trigger_func() OWNER TO "SynologyPhotos";

--
-- Name: decrease_concept_album_count_for_delete_bg_task(integer, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.decrease_concept_album_count_for_delete_bg_task(task_id integer, user_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  temp_table_name TEXT;
  query TEXT;
BEGIN
  temp_table_name := 'temp_table_for_delete_task_' || task_id;
  query := 'UPDATE concept_album_additional
  SET item_count = item_count - subquery.count
  FROM (
    SELECT id_concept, m.id_user, COUNT(*) AS count
    FROM many_unit_has_many_concept m
    JOIN unit ON unit.id = m.id_unit
    WHERE m.id_user = ' || user_id || ' AND unit.is_major AND unit.id_item IN (' || 'SELECT id FROM ' || quote_ident(temp_table_name) ||')
    GROUP BY id_concept, m.id_user
  ) AS subquery
  WHERE concept_album_additional.id_concept = subquery.id_concept AND concept_album_additional.id_user = subquery.id_user;';
  EXECUTE query;
END;
$$;


ALTER FUNCTION public.decrease_concept_album_count_for_delete_bg_task(task_id integer, user_id integer) OWNER TO "SynologyPhotos";

--
-- Name: decrease_person_album_count_for_delete_bg_task(integer, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.decrease_person_album_count_for_delete_bg_task(task_id integer, user_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  temp_table_name TEXT;
  query TEXT;
BEGIN
  temp_table_name := 'temp_table_for_delete_task_' || task_id;
  query := 'UPDATE person_item_count
  SET item_count = person_item_count.item_count - subquery.item_count
  FROM (
    SELECT id_person, id_user, COUNT(DISTINCT(id_item)) AS item_count
    FROM person_face_view
    WHERE id_user = ' || user_id || ' AND id_item IN (' || 'SELECT id FROM ' || quote_ident(temp_table_name) || ')
    GROUP BY id_person, id_user
  ) AS subquery
  WHERE person_item_count.id_person = subquery.id_person;';
  EXECUTE query;
END;
$$;


ALTER FUNCTION public.decrease_person_album_count_for_delete_bg_task(task_id integer, user_id integer) OWNER TO "SynologyPhotos";

--
-- Name: define_person_album_view_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.define_person_album_view_func() RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
BEGIN
  CREATE OR REPLACE VIEW public.person_album_view
  AS
    SELECT person_item_count.id_person,
      person.id_user,
      person.name,
      person.hidden,
      person.cover,
      person_item_count.item_count,
      person.normalized_name
    FROM person,
      person_item_count
  WHERE person_item_count.id_person = person.id AND person_item_count.id_user = person.id_user;
END
$$;


ALTER FUNCTION public.define_person_album_view_func() OWNER TO "SynologyPhotos";

--
-- Name: define_person_face_view_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.define_person_face_view_func() RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
BEGIN
  CREATE OR REPLACE VIEW public.person_face_view
  AS
    SELECT
      face.id,
      face.id_user,
      id_person,
      id_unit,
      score,
      is_major,
      id_item
    FROM face, unit
  WHERE unit.id = face.id_unit AND unit.id_user = face.id_user;
END
$$;


ALTER FUNCTION public.define_person_face_view_func() OWNER TO "SynologyPhotos";

--
-- Name: define_person_timeline_view_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.define_person_timeline_view_func() RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
BEGIN
  CREATE OR REPLACE VIEW public.person_timeline_view
  AS
    SELECT
      u.id_item,
      u.id_user,
      u.item_type,
      u.type AS unit_type,
      u.id AS id_unit,
      array_agg(DISTINCT f.id_person) AS id_person,
      u.takentime
    FROM unit u
    JOIN face f ON u.id = f.id_unit
  WHERE u.is_major = true
  GROUP BY u.id_user, u.id;
END
$$;


ALTER FUNCTION public.define_person_timeline_view_func() OWNER TO "SynologyPhotos";

--
-- Name: delete_expired_version_time_data_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_expired_version_time_data_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  count bigint;
  version_time text;
BEGIN
  version_time = TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
  EXECUTE format('SELECT count(*) FROM %s', version_time) INTO count;
  IF (count > 110000) THEN
        EXECUTE format('DELETE FROM %s WHERE version IN (SELECT version FROM %s order by version limit %L)', version_time, version_time, 10000);
  END IF;
    RETURN NEW;
END
$$;


ALTER FUNCTION public.delete_expired_version_time_data_func() OWNER TO "SynologyPhotos";

--
-- Name: delete_face_trigger_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_face_trigger_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  face_id integer;
  person_id integer;
  group_id integer;
  cluster_id integer;
  group_weight integer;
  remain_group_count integer;
  remain_cluster_count integer;
  person_group_table text;
  cluster_table text;
  person_table text;
  face_table text;
  cover integer;
  BEGIN
    person_group_table = TG_TABLE_SCHEMA || '.person_group';
    person_table = TG_TABLE_SCHEMA || '.person';
    cluster_table = TG_TABLE_SCHEMA || '.cluster';
    face_table = TG_TABLE_SCHEMA || '.face';
    person_id = OLD.id_person;
    group_id = OLD.id_person_group;
    face_id = OLD.id;
    IF (person_id IS NOT NULL) THEN
      EXECUTE format('SELECT cover FROM %I.person WHERE id = %s', TG_TABLE_SCHEMA, person_id) INTO cover;
      IF (cover IS NULL OR cover = OLD.id) THEN
        PERFORM public.update_person_best_cover(person_id, TG_TABLE_SCHEMA);
      END IF;
    END IF;
    IF (group_id IS NOT NULL) THEN
      EXECUTE 'SELECT COUNT(*) FROM ' || face_table || ' WHERE id_person_group = ' || group_id INTO group_weight;
      IF (group_weight > 0) THEN
        RETURN NULL;
      END IF;
      EXECUTE 'SELECT id_cluster FROM ' || person_group_table || ' WHERE id = ' || group_id INTO cluster_id;
      EXECUTE 'DELETE FROM ' || person_group_table || ' WHERE id = ' || group_id;
      IF (cluster_id IS NOT NULL) THEN
        EXECUTE 'SELECT COUNT(*) FROM ' || person_group_table || ' WHERE id_cluster = ' || cluster_id INTO remain_group_count;
        IF (remain_group_count > 0) THEN
          RETURN NULL;
        END IF;
        EXECUTE 'DELETE FROM ' || cluster_table || ' WHERE id = ' || cluster_id;
      END IF;
    END IF;
    IF (person_id IS NOT NULL) THEN
      EXECUTE 'SELECT COUNT(*) FROM ' || cluster_table || ' WHERE id_person = ' || person_id INTO remain_cluster_count;
      IF (remain_cluster_count > 0) THEN
        RETURN NULL;
      END IF;
      EXECUTE 'DELETE FROM ' || person_table || ' WHERE id = ' || person_id;
    END IF;
    RETURN NULL;
  END;
$$;


ALTER FUNCTION public.delete_face_trigger_func() OWNER TO "SynologyPhotos";

--
-- Name: delete_group_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_group_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
BEGIN
	DELETE FROM share_permission WHERE target_type = 2 AND target_id = OLD.id;
	RETURN NULL;
END
$$;


ALTER FUNCTION public.delete_group_func() OWNER TO "SynologyPhotos";

--
-- Name: delete_index_task_after_delete_unit(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_index_task_after_delete_unit() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
BEGIN
  DELETE FROM index_queue WHERE id_unit = OLD.id;
  RETURN NULL;
END;
$$;


ALTER FUNCTION public.delete_index_task_after_delete_unit() OWNER TO "SynologyPhotos";

--
-- Name: delete_item_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_item_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  delete_item_table text;
  new_version bigint;
  id_user integer;
BEGIN
  delete_item_table = TG_TABLE_SCHEMA || '.delete_item';
  SELECT id from user_info where id = OLD.id_user INTO id_user;
  if (id_user IS NOT NULL) THEN
    SELECT public.get_next_version_func(TG_TABLE_SCHEMA, id_user) INTO new_version;
    EXECUTE format('INSERT INTO %s (id_item, id_user, version) VALUES (%L, %L, %L)', delete_item_table, OLD.id, OLD.id_user, new_version);
  END IF;
  IF (OLD.is_similar_top_pick IS TRUE) THEN
    PERFORM public.update_similar_group_top_pick_func(OLD.id_similar_group);
  END IF;
  RETURN NULL;
END
$$;


ALTER FUNCTION public.delete_item_func() OWNER TO "SynologyPhotos";

--
-- Name: delete_item_to_update_normal_album_trigger_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_item_to_update_normal_album_trigger_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
    album_id integer;
    item_id integer;
    album_start_time bigint;
    album_end_time bigint;
    unit_time bigint;
    unit_table text;
    normal_album_table text;
    album_takentime_max bigint;
    album_takentime_min bigint;
BEGIN
  unit_table = TG_TABLE_SCHEMA || '.unit';
  normal_album_table = TG_TABLE_SCHEMA || '.normal_album';
  album_id = OLD.id_normal_album;
  item_id  = OLD.id_item;
  EXECUTE 'UPDATE ' || normal_album_table || ' SET item_count = COALESCE(item_count, 0) - 1 WHERE id =' || album_id;
  EXECUTE 'SELECT takentime FROM ' || unit_table || ' WHERE id_item = ' || item_id INTO unit_time;
  EXECUTE 'SELECT start_time, end_time FROM ' || normal_album_table ||
          ' WHERE id =' || album_id INTO album_start_time, album_end_time;
  IF (unit_time IS NULL OR unit_time = album_start_time OR unit_time = album_end_time) THEN
    EXECUTE format('SELECT max, min FROM public.get_unit_takentime_by_album(%L, %L)', album_id, TG_TABLE_SCHEMA) INTO album_takentime_max, album_takentime_min;
    EXECUTE 'UPDATE ' || normal_album_table || COALESCE(' SET start_time = ' || album_takentime_min, ' SET start_time = NULL') || COALESCE(', end_time = ' || album_takentime_max, ', end_time = NULL') || ' WHERE id = ' || album_id;
  END IF;
  RETURN NULL;
END
$$;


ALTER FUNCTION public.delete_item_to_update_normal_album_trigger_func() OWNER TO "SynologyPhotos";

--
-- Name: delete_nonexisting_geocoding_after_delete_unit(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_nonexisting_geocoding_after_delete_unit() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  geocoding_id integer;
  geocoding_table text;
  unit_count integer;
  unit_table text;
BEGIN
  IF (OLD.id_geocoding IS NULL) THEN
     RETURN OLD;
  END IF;
  unit_table = TG_TABLE_SCHEMA || '.unit';
  geocoding_table = TG_TABLE_SCHEMA || '.geocoding';
  geocoding_id = OLD.id_geocoding;
  EXECUTE 'SELECT COUNT(*) FROM ' || unit_table || ' WHERE id_geocoding = ' || geocoding_id INTO unit_count;
  IF (0 = unit_count) THEN
    EXECUTE 'DELETE FROM ' || geocoding_table || ' WHERE id = ' || geocoding_id;
  END IF;
  RETURN OLD;
END;
$$;


ALTER FUNCTION public.delete_nonexisting_geocoding_after_delete_unit() OWNER TO "SynologyPhotos";

--
-- Name: delete_normal_album_after_trigger_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_normal_album_after_trigger_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
    next_version bigint;
    delete_album_table text;
    share_table text;
    condition_album_item_table text;
    id_user integer;
    BEGIN
        delete_album_table = TG_TABLE_SCHEMA || '.delete_album';
        share_table = TG_TABLE_SCHEMA || '.share';
        IF (TG_OP = 'DELETE') THEN
           SELECT id from user_info where id = OLD.id_user INTO id_user;
           if (id_user IS NULL) THEN
               RETURN NULL;
           END IF;
           SELECT public.get_next_version_func(TG_TABLE_SCHEMA, OLD.id_user) INTO next_version;
           EXECUTE 'INSERT INTO ' || delete_album_table || ' (id_normal_album, id_user, version)
            VALUES ( '|| OLD.id || ', ' || OLD.id_user || ', ' || next_version || ')';
           IF OLD.passphrase_share IS NOT NULL THEN
               EXECUTE format('DELETE FROM %s WHERE passphrase = %L', share_table, OLD.passphrase_share);
           END IF;
           IF OLD.type = 1 THEN
               condition_album_item_table = TG_TABLE_SCHEMA || '.condition_album_item_' || OLD.id;
               EXECUTE format('DROP TABLE IF EXISTS %s', condition_album_item_table);
           END IF;
        END IF;
        RETURN NULL;
    END;
$$;


ALTER FUNCTION public.delete_normal_album_after_trigger_func() OWNER TO "SynologyPhotos";

--
-- Name: delete_redundant_migration_person_data_func(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_redundant_migration_person_data_func(user_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  DELETE FROM person_group_migration
  WHERE id_user = user_id AND
        NOT EXISTS (SELECT 1 FROM face_migration WHERE face_migration.id_person_group = person_group_migration.id);
  DELETE FROM cluster_migration
  WHERE id_user = user_id AND
        NOT EXISTS (SELECT 1 FROM person_group_migration WHERE person_group_migration.id_cluster = cluster_migration.id);
  DELETE FROM person_migration
  WHERE id_user = user_id AND
        NOT EXISTS (SELECT 1 FROM cluster_migration WHERE cluster_migration.id_person = person_migration.id);
END;
$$;


ALTER FUNCTION public.delete_redundant_migration_person_data_func(user_id integer) OWNER TO "SynologyPhotos";

--
-- Name: delete_redundant_person_data(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_redundant_person_data(user_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  DELETE FROM person_group
  WHERE id_user = user_id AND
        NOT EXISTS (SELECT 1 FROM face WHERE face.id_person_group = person_group.id);
  DELETE FROM cluster
  WHERE id_user = user_id AND
        NOT EXISTS (SELECT 1 FROM person_group WHERE person_group.id_cluster = cluster.id);
  DELETE FROM person
  WHERE id_user = user_id AND
        NOT EXISTS (SELECT 1 FROM cluster WHERE cluster.id_person = person.id);
END;
$$;


ALTER FUNCTION public.delete_redundant_person_data(user_id integer) OWNER TO "SynologyPhotos";

--
-- Name: delete_share_cascade_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_share_cascade_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
  DECLARE
    key text;
    delete_success bool;
  BEGIN
    key = OLD.passphrase;
    SELECT delete_sharing_entry(key) INTO delete_success;
    IF (delete_success = false) THEN
      RAISE EXCEPTION 'delete synoshareing entry failed';
    END IF;
    RETURN NULL;
  END
$$;


ALTER FUNCTION public.delete_share_cascade_func() OWNER TO "SynologyPhotos";

--
-- Name: delete_sharing_entry(text); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_sharing_entry(passphrase text) RETURNS boolean
    LANGUAGE c
    AS '/var/packages/SynologyPhotos/target/usr/lib/libsynofoto-db-trigger.so', 'pg_delete_sharing_entry';


ALTER FUNCTION public.delete_sharing_entry(passphrase text) OWNER TO "SynologyPhotos";

--
-- Name: delete_similar_timeline_after_item_update_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_similar_timeline_after_item_update_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF
    NEW.is_similar_top_pick IS FALSE
  THEN
    DELETE FROM public.similar_timeline WHERE id_item = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.delete_similar_timeline_after_item_update_func() OWNER TO "SynologyPhotos";

--
-- Name: delete_similar_timeline_by_unit_id(integer, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_similar_timeline_by_unit_id(target_id_unit integer, target_id_item integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  DELETE FROM public.similar_timeline
  WHERE id_unit = target_id_unit
  AND id_item = target_id_item
  AND (
    EXISTS (
      SELECT 1
      FROM unit
      WHERE id = target_id_unit
      AND is_major IS FALSE
    )
    OR EXISTS (
      SELECT 1
      FROM item
      WHERE id = target_id_item
      AND is_similar_top_pick IS FALSE
    )
  );
END;
$$;


ALTER FUNCTION public.delete_similar_timeline_by_unit_id(target_id_unit integer, target_id_item integer) OWNER TO "SynologyPhotos";

--
-- Name: delete_unit_version_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_unit_version_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  count integer;
  new_version bigint;
  item_table text;
  unit_table text;
  id_item integer;
  id_user integer;
BEGIN
  item_table = TG_TABLE_SCHEMA || '.item';
  unit_table = TG_TABLE_SCHEMA || '.unit';
  IF (TG_OP = 'DELETE') THEN
    id_item = OLD.id_item;
    EXECUTE format('SELECT id_user, count(*) FROM %s WHERE id_item = %L GROUP BY id_user', unit_table, id_item) INTO id_user, count;
    IF (count > 0) THEN
      SELECT public.get_next_version_func(TG_TABLE_SCHEMA, id_user) INTO new_version;
      EXECUTE format('UPDATE %s SET version = %L WHERE id_item = %L', unit_table, new_version, id_item);
    ELSE
      EXECUTE format('DELETE FROM %s WHERE id = %L', item_table, id_item);
    END IF;
    EXECUTE format('DELETE FROM index_queue WHERE id_user = %L and id_unit = %L', id_user, OLD.id);
    EXECUTE format('SELECT public.unit_update_normal_album_func(%L, %L)', TG_TABLE_SCHEMA, id_item);
    EXECUTE format('SELECT public.unit_update_condition_album_func(%L, %L)', TG_TABLE_SCHEMA, id_item);
  ELSIF (TG_OP = 'UPDATE' AND OLD.reindex_flag = NEW.reindex_flag) THEN
    id_item = OLD.id_item;
    IF (NEW.id_item != OLD.id_item) THEN
      EXECUTE format('SELECT public.unit_update_id_item_func(%L, %L, %L)', TG_TABLE_SCHEMA, id_item, NEW.id_item);
    END IF;
    IF (NEW.cache_key != OLD.cache_key) THEN
      EXECUTE format('SELECT public.unit_update_normal_album_func(%L, %L)', TG_TABLE_SCHEMA, id_item);
      EXECUTE format('SELECT public.unit_update_condition_album_func(%L, %L)', TG_TABLE_SCHEMA, id_item);
    END IF;
  END IF;
  RETURN NULL;
END
$$;


ALTER FUNCTION public.delete_unit_version_func() OWNER TO "SynologyPhotos";

--
-- Name: delete_user_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.delete_user_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
BEGIN
	DELETE FROM share_permission WHERE target_type = 1 AND target_id = OLD.id;
	RETURN NULL;
END
$$;


ALTER FUNCTION public.delete_user_func() OWNER TO "SynologyPhotos";

--
-- Name: display_item_type_order(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.display_item_type_order(item_type integer) RETURNS integer
    LANGUAGE plpgsql IMMUTABLE COST 1
    AS $$
DECLARE
  display_order integer;
  order_map integer[];
BEGIN
  -- kPhoto = 0,        order 0
  -- kVideo = 1,        order 4
  -- kBurst = 2,        order 6
  -- kLive = 3,         order 1
  -- kPhoto360 = 4,     order 3
  -- kVideo360 = 5,     order 5
  -- kMotionPhoto = 6,  order 2
  SELECT ARRAY[0, 4, 6, 1, 3, 5, 2] INTO order_map;
  display_order = order_map[item_type + 1];
  RETURN display_order;
END
$$;


ALTER FUNCTION public.display_item_type_order(item_type integer) OWNER TO "SynologyPhotos";

--
-- Name: display_shared_status_order(integer, integer, boolean); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.display_shared_status_order(id_user integer, owner_id integer, enable boolean) RETURNS integer
    LANGUAGE plpgsql IMMUTABLE COST 1
    AS $$
DECLARE
  display_order integer;
BEGIN
  -- shared,         order 0
  -- shared_with_me, order 1
  -- not shared,     order 2
  IF (enable AND id_user = owner_id) THEN
    display_order = 0;
  ELSIF (enable AND id_user != owner_id) THEN
    display_order = 1;
  ELSE
    display_order = 2;
  END IF;
  RETURN display_order;
END
$$;


ALTER FUNCTION public.display_shared_status_order(id_user integer, owner_id integer, enable boolean) OWNER TO "SynologyPhotos";

--
-- Name: drop_read_only_trigger_func(text); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.drop_read_only_trigger_func(table_name text) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS read_only_trigger ON %I CASCADE', table_name);
END;
$$;


ALTER FUNCTION public.drop_read_only_trigger_func(table_name text) OWNER TO "SynologyPhotos";

--
-- Name: drop_temp_table_for_delete_task(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.drop_temp_table_for_delete_task(task_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  temp_table_name TEXT;
BEGIN
  temp_table_name := 'temp_table_for_delete_task_' || task_id;
  EXECUTE 'DROP TABLE ' || temp_table_name;
END;
$$;


ALTER FUNCTION public.drop_temp_table_for_delete_task(task_id integer) OWNER TO "SynologyPhotos";

--
-- Name: face_update_unit_version_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.face_update_unit_version_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
  DECLARE
    new_version bigint;
    unit_table text;
  BEGIN
    unit_table = TG_TABLE_SCHEMA || '.unit';
    IF (TG_OP = 'UPDATE' AND NEW.id_person != OLD.id_person) THEN
         SELECT public.get_next_version_func(TG_TABLE_SCHEMA, NEW.id_user) INTO new_version;
         EXECUTE 'UPDATE ' || unit_table || ' SET version = ' || new_version || ' WHERE id = ' || NEW.ref_id_unit;
    END IF;
    RETURN NULL;
  END
$$;


ALTER FUNCTION public.face_update_unit_version_func() OWNER TO "SynologyPhotos";

--
-- Name: get_json_value(json, text); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.get_json_value(json_data json, key text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
   RETURN json_data ->> key;
END
$$;


ALTER FUNCTION public.get_json_value(json_data json, key text) OWNER TO "SynologyPhotos";

--
-- Name: get_next_version_func(text, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.get_next_version_func(schema text, id_user integer) RETURNS bigint
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  next_version bigint;
  version_table text;
  id_user_bucket integer;
BEGIN
  id_user_bucket := CASE WHEN id_user = 0 THEN 0 ELSE (id_user - 1) % 13 + 1 END;
  version_table = schema || '.version_time_' || id_user_bucket;
  EXECUTE 'INSERT INTO ' || version_table || '(modified_time)
    SELECT round(extract(epoch FROM now()) * 1000) RETURNING version ' INTO next_version;
  RETURN next_version;
END
$$;


ALTER FUNCTION public.get_next_version_func(schema text, id_user integer) OWNER TO "SynologyPhotos";

--
-- Name: get_unit_takentime_by_album(integer, text); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.get_unit_takentime_by_album(id_album integer, schema text) RETURNS TABLE(max bigint, min bigint)
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  unit_table text;
  many_table text;
BEGIN
    unit_table = schema || '.unit';
    many_table = schema || '.many_item_has_many_normal_album';
    RETURN QUERY EXECUTE 'SELECT MAX(takentime), MIN(takentime) FROM ' || unit_table || ' WHERE id_item IN(
        SELECT id_item FROM '|| many_table || ' WHERE id_normal_album = ' || id_album ||')';
END;
$$;


ALTER FUNCTION public.get_unit_takentime_by_album(id_album integer, schema text) OWNER TO "SynologyPhotos";

--
-- Name: get_unit_takentime_by_condition_album(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.get_unit_takentime_by_condition_album(id_album integer) RETURNS TABLE(max bigint, min bigint)
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  unit_table text;
  item_table text;
BEGIN
    unit_table = 'public.unit';
    item_table = 'public.condition_album_item_' || id_album;
    RETURN QUERY EXECUTE 'SELECT MAX(takentime), MIN(takentime) FROM ' || unit_table || ' WHERE id_item IN(
        SELECT id_item FROM '|| item_table ||')';
END;
$$;


ALTER FUNCTION public.get_unit_takentime_by_condition_album(id_album integer) OWNER TO "SynologyPhotos";

--
-- Name: increase_album_version_func(text, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.increase_album_version_func(schema text, album_id integer) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
    album_table  text;
    new_version integer;
    item_id integer;
    id_user integer;
BEGIN
    album_table = schema || '.album';
    EXECUTE 'SELECT id_user FROM ' || album_table || ' WHERE id = ' || album_id INTO id_user;
    SELECT public.get_next_version_func(schema, id_user) INTO new_version;
    EXECUTE format('UPDATE %s SET version = %L WHERE id = %L', album_table, new_version, album_id);
END
$$;


ALTER FUNCTION public.increase_album_version_func(schema text, album_id integer) OWNER TO "SynologyPhotos";

--
-- Name: increase_concept_album_additional(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.increase_concept_album_additional() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF EXISTS (SELECT id_concept, id_user FROM concept_album_additional WHERE id_user = NEW.id_user AND id_concept = NEW.id_concept) THEN
    UPDATE concept_album_additional SET item_count = item_count + 1
    WHERE
      (SELECT is_major FROM unit WHERE unit.id = NEW.id_unit)
      AND concept_album_additional.id_user = NEW.id_user
      AND concept_album_additional.id_concept = NEW.id_concept;
  ELSIF (SELECT is_major FROM unit WHERE id = NEW.id_unit) THEN
    INSERT INTO concept_album_additional (id_user, id_concept, item_count) VALUES (NEW.id_user, NEW.id_concept, 1);
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION public.increase_concept_album_additional() OWNER TO "SynologyPhotos";

--
-- Name: increase_concept_album_count_by_item_id(integer, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.increase_concept_album_count_by_item_id(item_id integer, user_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE concept_album_additional
  SET item_count = item_count + subquery.count
  FROM (
    SELECT id_concept, id_user, COUNT(*) AS count
    FROM many_unit_has_many_concept m
    JOIN unit ON unit.id = m.id_unit
    WHERE m.id_user = user_id AND unit.is_major AND unit.id_item = item_id
    GROUP BY id_concept
  ) AS subquery
  WHERE concept_album_additional.id_concept = subquery.id_concept AND concept_album_additional.id_user = user_id;
END;
$$;


ALTER FUNCTION public.increase_concept_album_count_by_item_id(item_id integer, user_id integer) OWNER TO "SynologyPhotos";

--
-- Name: increase_person_album_count_by_item_id(integer, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.increase_person_album_count_by_item_id(item_id integer, user_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE person_item_count
  SET item_count = item_count + subquery.count
  FROM (
    SELECT id_person, COUNT(DISTINCT(id_item)) AS count
    FROM person_face_view
    WHERE id_item = item_id AND id_user = user_id
    GROUP BY id_person
  ) AS subquery
  WHERE person_item_count.id_person = subquery.id_person;
END;
$$;


ALTER FUNCTION public.increase_person_album_count_by_item_id(item_id integer, user_id integer) OWNER TO "SynologyPhotos";

--
-- Name: init_user_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.init_user_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  root_id integer;
BEGIN
  SELECT nextval('folder_id_seq') INTO root_id;
  INSERT INTO folder (id, id_user, name, parent, name_for_sort, shared, permission_parent) VALUES (root_id, NEW.id, '/', root_id, '/', false, root_id);
  RETURN NULL;
END
$$;


ALTER FUNCTION public.init_user_func() OWNER TO "SynologyPhotos";

--
-- Name: insert_into_temp_table_for_delete_task(integer, integer[]); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.insert_into_temp_table_for_delete_task(task_id integer, VARIADIC ids integer[]) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  sql_statement TEXT;
BEGIN
  sql_statement := 'INSERT INTO temp_table_for_delete_task_' || task_id || ' (id) VALUES ';
  sql_statement := sql_statement || '(' || array_to_string(ids, '),(') || ')';
  EXECUTE sql_statement;
END;
$$;


ALTER FUNCTION public.insert_into_temp_table_for_delete_task(task_id integer, VARIADIC ids integer[]) OWNER TO "SynologyPhotos";

--
-- Name: insert_item_to_update_condition_album_func(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.insert_item_to_update_condition_album_func(id_album integer) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  item_table text;
  condition_album_table text;
  max_time bigint;
  min_time bigint;
  count integer;
BEGIN
  condition_album_table = 'public.condition_album';
  item_table = 'public.condition_album_item_' || id_album;
  EXECUTE 'SELECT count(*) FROM ' || item_table INTO count;
  EXECUTE format('SELECT max, min FROM public.get_unit_takentime_by_condition_album(%L)', id_album) INTO max_time, min_time;
  EXECUTE 'UPDATE ' || condition_album_table || COALESCE(' SET start_time = ' || min_time, ' SET start_time = NULL') || COALESCE(', end_time = ' || max_time, ', end_time = NULL') || ', item_count = ' || count || ' WHERE id = ' || id_album;
END;
$$;


ALTER FUNCTION public.insert_item_to_update_condition_album_func(id_album integer) OWNER TO "SynologyPhotos";

--
-- Name: insert_item_to_update_normal_album_func(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.insert_item_to_update_normal_album_func(id_album integer) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  many_table text;
  normal_album_table text;
  max_time bigint;
  min_time bigint;
  count integer;
BEGIN
  normal_album_table = 'public.normal_album';
  many_table = 'public.many_item_has_many_normal_album';
  EXECUTE 'SELECT count(*) FROM ' || many_table || ' WHERE id_normal_album = ' || id_album INTO count;
  EXECUTE format('SELECT max, min FROM public.get_unit_takentime_by_album(%L, %L)', id_album, 'public') INTO max_time, min_time;
  EXECUTE 'UPDATE ' || normal_album_table || COALESCE(' SET start_time = ' || min_time, ' SET start_time = NULL') || COALESCE(', end_time = ' || max_time, ', end_time = NULL') || ', item_count = ' || count || ' WHERE id = ' || id_album;
END;
$$;


ALTER FUNCTION public.insert_item_to_update_normal_album_func(id_album integer) OWNER TO "SynologyPhotos";

--
-- Name: insert_similar_hash_missing_units_func(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.insert_similar_hash_missing_units_func(user_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO similar_hash (id_unit, id_user, takentime, is_major, id_item, type)
  SELECT unit.id, unit.id_user, unit.takentime, unit.is_major, unit.id_item, unit.type
  FROM unit LEFT JOIN similar_hash
  ON unit.id = similar_hash.id_unit
  WHERE similar_hash.id_unit IS NULL and unit.id_user = user_id;
END;
$$;


ALTER FUNCTION public.insert_similar_hash_missing_units_func(user_id integer) OWNER TO "SynologyPhotos";

--
-- Name: insert_similar_timeline_after_item_update_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.insert_similar_timeline_after_item_update_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  unit_id integer;
  unit_takentime bigint;
  similar_group_item_count bigint;
BEGIN
  IF
    NEW.is_similar_top_pick IS TRUE OR NEW.id_similar_group IS NULL
  THEN
    SELECT id, takentime INTO unit_id, unit_takentime FROM unit WHERE NEW.id = unit.id_item AND unit.is_major IS TRUE;
    SELECT
      item_count INTO similar_group_item_count
    FROM
      similar_group
    WHERE
      NEW.id_similar_group = similar_group.id;
    INSERT INTO public.similar_timeline
    VALUES (unit_id, NEW.id, NEW.id_user, unit_takentime, NEW.id_similar_group, similar_group_item_count)
    ON CONFLICT (id_unit, id_item, id_user)
    DO UPDATE SET
      takentime = EXCLUDED.takentime,
      id_similar_group = EXCLUDED.id_similar_group,
      similar_group_item_count = EXCLUDED.similar_group_item_count;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.insert_similar_timeline_after_item_update_func() OWNER TO "SynologyPhotos";

--
-- Name: insert_similar_timeline_by_unit_id(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.insert_similar_timeline_by_unit_id(target_id_unit integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO public.similar_timeline (id_unit, id_item, id_user, takentime)
  SELECT
    unit.id,
    unit.id_item,
    unit.id_user,
    unit.takentime
  FROM
    unit, item
  WHERE unit.id = target_id_unit AND unit.id_item = item.id
  AND unit.is_major is TRUE
  AND item.is_similar_top_pick is NOT FALSE
  ON CONFLICT (id_unit, id_item, id_user)
  DO NOTHING;
END;
$$;


ALTER FUNCTION public.insert_similar_timeline_by_unit_id(target_id_unit integer) OWNER TO "SynologyPhotos";

--
-- Name: level_concept_timeline(bigint, bigint, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.level_concept_timeline(start_time bigint, end_time bigint, concept_id integer, user_id integer, level_param integer) RETURNS TABLE(level integer, admin smallint, id_unit integer, item_count bigint, id_item integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        CASE
            WHEN level_param = 1 THEN g.level_1
            WHEN level_param = 2 THEN g.level_2
            WHEN level_param = 3 THEN g.level_3
            WHEN level_param = 4 THEN g.level_4
            WHEN level_param = 5 THEN g.level_5
            WHEN level_param = 6 THEN g.level_6
            ELSE NULL
        END AS level,
        CASE
            WHEN level_param = 1 THEN g.admin_1
            WHEN level_param = 2 THEN g.admin_2
            WHEN level_param = 3 THEN g.admin_3
            WHEN level_param = 4 THEN g.admin_4
            WHEN level_param = 5 THEN g.admin_5
            WHEN level_param = 6 THEN g.admin_6
            ELSE NULL
        END AS admin,
        MIN(u.id) AS id_unit,
        COUNT(DISTINCT u.id_item) AS item_count,
        MIN(u.id_item) AS id_item
    FROM
        public.unit u
    JOIN
        many_unit_has_many_concept r ON u.id = r.id_unit
    JOIN
        public.geocoding g ON u.id_geocoding = g.id
    WHERE
        u.takentime BETWEEN start_time AND end_time
        AND r.id_concept = concept_id
        AND u.id_user = user_id
        AND u.is_major = true
    GROUP BY
        level, admin
    ORDER BY
        item_count DESC NULLS LAST,
        id_item ASC NULLS LAST
    LIMIT 4;
END;
$$;


ALTER FUNCTION public.level_concept_timeline(start_time bigint, end_time bigint, concept_id integer, user_id integer, level_param integer) OWNER TO "SynologyPhotos";

--
-- Name: level_general_tag_timeline(bigint, bigint, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.level_general_tag_timeline(start_time bigint, end_time bigint, general_tag_id integer, user_id integer, level_param integer) RETURNS TABLE(level integer, admin smallint, id_unit integer, item_count bigint, id_item integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        CASE
            WHEN level_param = 1 THEN g.level_1
            WHEN level_param = 2 THEN g.level_2
            WHEN level_param = 3 THEN g.level_3
            WHEN level_param = 4 THEN g.level_4
            WHEN level_param = 5 THEN g.level_5
            WHEN level_param = 6 THEN g.level_6
            ELSE NULL
        END AS level,
        CASE
            WHEN level_param = 1 THEN g.admin_1
            WHEN level_param = 2 THEN g.admin_2
            WHEN level_param = 3 THEN g.admin_3
            WHEN level_param = 4 THEN g.admin_4
            WHEN level_param = 5 THEN g.admin_5
            WHEN level_param = 6 THEN g.admin_6
            ELSE NULL
        END AS admin,
        MIN(u.id) AS id_unit,
        COUNT(DISTINCT u.id_item) AS item_count,
        MIN(u.id_item) AS id_item
    FROM
        public.unit u
    JOIN
        many_unit_has_many_general_tag r ON u.id = r.id_unit
    JOIN
        public.geocoding g ON u.id_geocoding = g.id
    WHERE
        u.takentime BETWEEN start_time AND end_time
        AND r.id_general_tag = general_tag_id
        AND u.id_user = user_id
        AND u.is_major = true
    GROUP BY
        level, admin
    ORDER BY
        item_count DESC NULLS LAST,
        id_item ASC NULLS LAST
    LIMIT 4;
END;
$$;


ALTER FUNCTION public.level_general_tag_timeline(start_time bigint, end_time bigint, general_tag_id integer, user_id integer, level_param integer) OWNER TO "SynologyPhotos";

--
-- Name: level_person_timeline(bigint, bigint, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.level_person_timeline(start_time bigint, end_time bigint, person_id integer, user_id integer, level_param integer) RETURNS TABLE(level integer, admin smallint, id_unit integer, item_count bigint, id_item integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        CASE
            WHEN level_param = 1 THEN g.level_1
            WHEN level_param = 2 THEN g.level_2
            WHEN level_param = 3 THEN g.level_3
            WHEN level_param = 4 THEN g.level_4
            WHEN level_param = 5 THEN g.level_5
            WHEN level_param = 6 THEN g.level_6
            ELSE NULL
        END AS level,
        CASE
            WHEN level_param = 1 THEN g.admin_1
            WHEN level_param = 2 THEN g.admin_2
            WHEN level_param = 3 THEN g.admin_3
            WHEN level_param = 4 THEN g.admin_4
            WHEN level_param = 5 THEN g.admin_5
            WHEN level_param = 6 THEN g.admin_6
            ELSE NULL
        END AS admin,
        MIN(u.id) AS id_unit,
        COUNT(DISTINCT u.id_item) AS item_count,
        MIN(u.id_item) AS id_item
    FROM
        public.unit u
    JOIN
        public.face f ON u.id = f.id_unit
    JOIN
        public.geocoding g ON u.id_geocoding = g.id
    WHERE
        u.takentime BETWEEN start_time AND end_time
        AND f.id_person = person_id
        AND u.id_user = user_id
        AND u.is_major = true
    GROUP BY
        level, admin
    ORDER BY
        item_count DESC NULLS LAST,
        id_item ASC NULLS LAST
    LIMIT 4;
END;
$$;


ALTER FUNCTION public.level_person_timeline(start_time bigint, end_time bigint, person_id integer, user_id integer, level_param integer) OWNER TO "SynologyPhotos";

--
-- Name: level_search_timeline(bigint, bigint, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.level_search_timeline(start_time bigint, end_time bigint, _ integer, user_id integer, level_param integer) RETURNS TABLE(level integer, admin smallint, id_unit integer, item_count bigint, id_item integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        CASE
            WHEN level_param = 1 THEN g.level_1
            WHEN level_param = 2 THEN g.level_2
            WHEN level_param = 3 THEN g.level_3
            WHEN level_param = 4 THEN g.level_4
            WHEN level_param = 5 THEN g.level_5
            WHEN level_param = 6 THEN g.level_6
            ELSE NULL
        END AS level,
        CASE
            WHEN level_param = 1 THEN g.admin_1
            WHEN level_param = 2 THEN g.admin_2
            WHEN level_param = 3 THEN g.admin_3
            WHEN level_param = 4 THEN g.admin_4
            WHEN level_param = 5 THEN g.admin_5
            WHEN level_param = 6 THEN g.admin_6
            ELSE NULL
        END AS admin,
        MIN(u.id) AS id_unit,
        COUNT(DISTINCT u.id_item) AS item_count,
        MIN(u.id_item) AS id_item
    FROM
        public.unit u
    JOIN
        search_timeline s ON u.id = s.id_unit
    JOIN
        public.geocoding g ON u.id_geocoding = g.id
    WHERE
        u.takentime BETWEEN start_time AND end_time
        AND u.id_user = user_id
        AND u.is_major = true
    GROUP BY
        level, admin
    ORDER BY
        item_count DESC NULLS LAST,
        id_item ASC NULLS LAST
    LIMIT 4;
END;
$$;


ALTER FUNCTION public.level_search_timeline(start_time bigint, end_time bigint, _ integer, user_id integer, level_param integer) OWNER TO "SynologyPhotos";

--
-- Name: list_cover_for_id_folders(integer, integer, integer[]); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.list_cover_for_id_folders(cover_limit integer, user_id integer, id_folders integer[]) RETURNS TABLE(id_folder integer, id_unit integer[], cache_key text[])
    LANGUAGE plpgsql
    AS $$
DECLARE
  folder_id integer;
  id_cover integer[];
  id_cover_cache_key text[];
BEGIN
  FOREACH folder_id IN ARRAY id_folders
  LOOP
    SELECT ARRAY_AGG(id), ARRAY_AGG(subquery.cache_key) INTO id_cover, id_cover_cache_key
    FROM (
      SELECT id, unit.cache_key
      FROM unit
      WHERE unit.id_folder = folder_id AND unit.is_major = TRUE AND unit.id_user = user_id
      ORDER BY id DESC
      LIMIT cover_limit
    ) AS subquery;
    RETURN QUERY SELECT folder_id, id_cover, id_cover_cache_key;
  END LOOP;
END;
$$;


ALTER FUNCTION public.list_cover_for_id_folders(cover_limit integer, user_id integer, id_folders integer[]) OWNER TO "SynologyPhotos";

--
-- Name: metadata_update_unit_version_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.metadata_update_unit_version_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  new_version bigint;
  unit_table text;
  id_user integer;
BEGIN
  unit_table = TG_TABLE_SCHEMA || '.unit';
  IF (TG_OP = 'UPDATE') THEN
    IF (NEW.description != OLD.description OR NEW.orientation != OLD.orientation) THEN
       EXECUTE 'SELECT id_user FROM ' || unit_table || ' WHERE id = ' || NEW.id_unit INTO id_user;
       SELECT public.get_next_version_func(TG_TABLE_SCHEMA, id_user) INTO new_version;
       EXECUTE 'UPDATE ' || unit_table || ' SET version = ' || new_version || ' WHERE id = ' || NEW.id_unit;
    END IF;
  END IF;
  RETURN NULL;
END
$$;


ALTER FUNCTION public.metadata_update_unit_version_func() OWNER TO "SynologyPhotos";

--
-- Name: notification_rotate_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.notification_rotate_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
    count integer;
    ctime bigint;
    notification_table text;
BEGIN
    notification_table = TG_TABLE_SCHEMA || '.notification';
    EXECUTE 'SELECT count(*) FROM ' || notification_table INTO count;
    IF (count > 200) THEN
          EXECUTE 'SELECT createtime FROM ' || notification_table || ' ORDER BY createtime DESC OFFSET 200 LIMIT 1' INTO ctime;
          EXECUTE 'DELETE FROM ' || notification_table || ' WHERE createtime <= ' || ctime;
    END IF;
    RETURN NULL;
END;
$$;


ALTER FUNCTION public.notification_rotate_func() OWNER TO "SynologyPhotos";

--
-- Name: read_only_table(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.read_only_table() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
BEGIN
    RAISE EXCEPTION 'Table is read-only';
END;
$$;


ALTER FUNCTION public.read_only_table() OWNER TO "SynologyPhotos";

--
-- Name: recalculate_concept_album_additional(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.recalculate_concept_album_additional(user_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE concept_album_additional set item_count = 0 WHERE id_user = user_id;
  INSERT INTO
  concept_album_additional (id_concept, item_count, id_user)
  SELECT
    id_concept, COUNT(*) as item_count, user_id as id_user
  FROM
    many_unit_has_many_concept m
    JOIN unit on unit.id = m.id_unit
  WHERE
    m.id_user = user_id
    AND unit.is_major
  GROUP BY id_concept, m.id_user
  ON CONFLICT(id_user, id_concept) DO UPDATE
  SET
    (id_concept, item_count, id_user) = (EXCLUDED.id_concept, EXCLUDED.item_count, EXCLUDED.id_user);
END;
$$;


ALTER FUNCTION public.recalculate_concept_album_additional(user_id integer) OWNER TO "SynologyPhotos";

--
-- Name: recalculate_person_album_item_count(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.recalculate_person_album_item_count(user_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO
  person_item_count (id_person, id_user, item_count)
    SELECT id_person, id_user, count(DISTINCT id_item) AS item_count
    FROM person_face_view
    WHERE id_user = user_id AND is_major = true AND id_person IS NOT NULL
    GROUP BY id_person, id_user
  ON CONFLICT(id_user, id_person) DO UPDATE
  SET
    (id_person, id_user, item_count) = (EXCLUDED.id_person, EXCLUDED.id_user, EXCLUDED.item_count);
  DELETE FROM person_item_count WHERE item_count = 0 AND id_user = user_id;
END;
$$;


ALTER FUNCTION public.recalculate_person_album_item_count(user_id integer) OWNER TO "SynologyPhotos";

--
-- Name: redefine_migration_constraint_func(text[]); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.redefine_migration_constraint_func(production_tables text[]) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $_$
DECLARE
  table_name TEXT;
  r RECORD;
  referenced_table_name TEXT;
BEGIN
  CREATE TEMP TABLE _migration_table_fk_def (
    tb_name TEXT,
    fk_name TEXT,
    fk_def TEXT
  );
  -- change the definition of foreign key constraint to *_migration table
  FOR table_name IN SELECT unnest(production_tables) LOOP
    -- insert table name, fk name and fk defination into _migration_table_fk_def
    INSERT INTO _migration_table_fk_def (tb_name, fk_name, fk_def)
    SELECT CAST(conrelid::regclass AS text) AS tb_name,
           conname AS fk_name,
           pg_get_constraintdef(c.oid) AS fk_def
    FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE CAST(conrelid::regclass AS text) = table_name AND contype = 'f';
    -- if referenced table is in production_tables, rename it to `referenced_table_name`_migration
    FOR r IN SELECT * FROM _migration_table_fk_def WHERE tb_name = table_name LOOP
      -- return `REFERENCES` and `referenced_table_name` from fk_def, something like$1 "REFERENCES person_group"
      referenced_table_name := (SELECT substring(r.fk_def, '(REFERENCES[[:space:]]+[A-Za-z0-9_]+)'));
      if split_part(referenced_table_name, ' ', 2) IN (SELECT unnest(production_tables)) THEN
        UPDATE _migration_table_fk_def
        SET fk_def = replace(fk_def, referenced_table_name, referenced_table_name || '_migration')
        WHERE fk_name = r.fk_name;
      END IF;
    END LOOP;
    FOR r IN SELECT * FROM _migration_table_fk_def WHERE tb_name = table_name LOOP
      EXECUTE format('ALTER TABLE %s_migration DROP CONSTRAINT IF EXISTS %I', table_name, r.fk_name);
      EXECUTE format('ALTER TABLE %s_migration ADD CONSTRAINT %I %s', table_name, r.fk_name, r.fk_def);
    END LOOP;
  END LOOP;
  DROP TABLE  _migration_table_fk_def;
END
$_$;


ALTER FUNCTION public.redefine_migration_constraint_func(production_tables text[]) OWNER TO "SynologyPhotos";

--
-- Name: remove_person_migration_tables_id_sequence_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.remove_person_migration_tables_id_sequence_func() RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
BEGIN
  ALTER TABLE IF EXISTS face_migration
    ALTER COLUMN id DROP DEFAULT;
  ALTER TABLE IF EXISTS person_group_migration
    ALTER COLUMN id DROP DEFAULT;
  ALTER TABLE IF EXISTS cluster_migration
    ALTER COLUMN id DROP DEFAULT;
  ALTER TABLE IF EXISTS person_migration
    ALTER COLUMN id DROP DEFAULT;
END;
$$;


ALTER FUNCTION public.remove_person_migration_tables_id_sequence_func() OWNER TO "SynologyPhotos";

--
-- Name: rename_fk_constraints(text[]); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.rename_fk_constraints(replaced_patterns text[]) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  r RECORD;
  new_name text;
  exists_check int;
BEGIN
  FOR r IN
    SELECT
      con.conname AS old_name,
      c.relname   AS table_name,
      n.nspname   AS schema_name
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE con.contype = 'f'
      AND con.conname = ANY (replaced_patterns)
  LOOP
    new_name := r.table_name || '_' || r.old_name;
    SELECT 1 INTO exists_check
    FROM pg_constraint
    WHERE conname = new_name;
    IF exists_check IS NULL THEN
      EXECUTE format(
        'ALTER TABLE %I.%I RENAME CONSTRAINT %I TO %I;',
          r.schema_name,
          r.table_name,
          r.old_name,
          new_name
      );
    END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION public.rename_fk_constraints(replaced_patterns text[]) OWNER TO "SynologyPhotos";

--
-- Name: set_person_item_count_fk_refer_to_production_tables_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.set_person_item_count_fk_refer_to_production_tables_func() RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
BEGIN
  TRUNCATE person_item_count;
  ALTER TABLE person_item_count
  DROP CONSTRAINT IF EXISTS person_item_count_person_fk,
  ADD CONSTRAINT person_item_count_person_fk FOREIGN KEY (id_person) REFERENCES person(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;
END
$$;


ALTER FUNCTION public.set_person_item_count_fk_refer_to_production_tables_func() OWNER TO "SynologyPhotos";

--
-- Name: set_person_migration_original_tables_backup_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.set_person_migration_original_tables_backup_func() RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  production_tables CONSTANT TEXT[] := ARRAY['face', 'person_group', 'cluster', 'person'];
  var_table_name TEXT;
  r RECORD;
BEGIN
  FOR var_table_name IN SELECT unnest(production_tables) LOOP
    EXECUTE format('DROP TABLE IF EXISTS %s_backup CASCADE', var_table_name);
    EXECUTE format('ALTER SEQUENCE %s_id_seq RENAME TO %s_id_seq_backup', var_table_name, var_table_name);
    FOR r in SELECT indexname AS index_name FROM pg_indexes WHERE tablename = var_table_name LOOP
      EXECUTE format('ALTER INDEX %I RENAME TO %s_backup', r.index_name, r.index_name);
    END LOOP;
    FOR r in SELECT constraint_name
             FROM information_schema.table_constraints
             WHERE table_name = var_table_name AND constraint_type = 'FOREIGN KEY'
    LOOP
      EXECUTE format('ALTER TABLE %I DROP CONSTRAINT %I CASCADE', var_table_name, r.constraint_name);
    END LOOP;
    FOR r in SELECT DISTINCT trigger_name FROM information_schema.triggers WHERE event_object_table = var_table_name LOOP
      EXECUTE format('DROP TRIGGER %I ON %I CASCADE', r.trigger_name, var_table_name);
    END LOOP;
    FOR r in SELECT rulename AS rule_name FROM pg_rewrite pr JOIN pg_class c
          ON c.oid = pr.ev_class WHERE c.relname = var_table_name
    LOOP
      EXECUTE format('DROP RULE %I ON %I CASCADE', r.rule_name, var_table_name);
    END LOOP;
    IF var_table_name = 'face' OR var_table_name = 'person_group' THEN
      EXECUTE format('ALTER TABLE %I DROP COLUMN feature', var_table_name);
    END IF;
    EXECUTE format('ALTER TABLE %I RENAME TO %s_backup', var_table_name, var_table_name);
  END LOOP;
END
$$;


ALTER FUNCTION public.set_person_migration_original_tables_backup_func() OWNER TO "SynologyPhotos";

--
-- Name: set_person_migration_tables_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.set_person_migration_tables_func() RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  production_tables CONSTANT TEXT[] := ARRAY['face', 'person_group', 'cluster', 'person'];
  table_name TEXT;
  r RECORD;
  production_index_name TEXT;
BEGIN
  FOR table_name IN SELECT unnest(production_tables) LOOP
    EXECUTE format('ALTER TABLE %s_migration RENAME TO %s', table_name, table_name);
    EXECUTE format('CREATE SEQUENCE %s_id_seq OWNED BY %I.id', table_name, table_name);
    EXECUTE format('SELECT setval(%L, max(id)) FROM %I', table_name || '_id_seq', table_name);
    EXECUTE format('ALTER TABLE %I ALTER COLUMN id SET DEFAULT nextval(%L)', table_name, table_name || '_id_seq');
    -- collect all index_def fist and drop duplicate indexes
    DECLARE
      idx_seen TEXT[] := ARRAY[]::TEXT[];
    BEGIN
      FOR r IN SELECT indexname AS index_name, split_part(indexdef, 'USING ', 2) AS index_def FROM pg_indexes WHERE tablename = table_name LOOP
        IF r.index_def = ANY(idx_seen) THEN
          -- found existed, drop index
          EXECUTE format('DROP INDEX IF EXISTS %I', r.index_name);
        ELSE
          -- not found, rename to production index name
          production_index_name := (SELECT index_name FROM production_table_index_mapping WHERE tb_name = table_name AND index_def = r.index_def LIMIT 1);
          EXECUTE format('ALTER INDEX %I RENAME TO %s', r.index_name, production_index_name);
          idx_seen := array_append(idx_seen, r.index_def);
        END IF;
      END LOOP;
    END;
  END LOOP;
  DROP TABLE production_table_index_mapping;
  CREATE TRIGGER delete_face_trigger
    AFTER DELETE
    ON public.face
    FOR EACH ROW
    EXECUTE PROCEDURE public.delete_face_trigger_func();
  CREATE TRIGGER update_face_trigger
    AFTER UPDATE
    ON public.face
    FOR EACH ROW
    EXECUTE PROCEDURE public.update_face_func();
  DROP RULE IF EXISTS drop_face_lo_on_update ON public.face CASCADE;
  CREATE RULE drop_face_lo_on_update AS ON UPDATE
    TO public.face
    WHERE NEW.picture != OLD.picture
    DO ALSO (SELECT lo_unlink(OLD.picture));
  DROP RULE IF EXISTS drop_face_lo_on_delete ON public.face CASCADE;
  CREATE RULE drop_face_lo_on_delete AS ON DELETE
    TO public.face
    DO ALSO (SELECT lo_unlink(OLD.picture));
  DROP TABLE IF EXISTS face_migration_manual_map;
END
$$;


ALTER FUNCTION public.set_person_migration_tables_func() OWNER TO "SynologyPhotos";

--
-- Name: set_person_table_read_only_top_down_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.set_person_table_read_only_top_down_func() RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
BEGIN
  PERFORM public.drop_read_only_trigger_func('face');
  PERFORM public.drop_read_only_trigger_func('person_group');
  PERFORM public.drop_read_only_trigger_func('cluster');
  PERFORM public.drop_read_only_trigger_func('person');
  PERFORM public.create_read_only_trigger_func('face');
  PERFORM public.create_read_only_trigger_func('person_group');
  PERFORM public.create_read_only_trigger_func('cluster');
  PERFORM public.create_read_only_trigger_func('person');
END
$$;


ALTER FUNCTION public.set_person_table_read_only_top_down_func() OWNER TO "SynologyPhotos";

--
-- Name: share_permission_update_album_version_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.share_permission_update_album_version_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  new_version bigint;
  album_table text;
  passphrase text;
  id_user integer;
BEGIN
  album_table = TG_TABLE_SCHEMA || '.album';
  IF (TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND (NEW.permission != OLD.permission))) THEN
    passphrase = NEW.passphrase_share;
    id_user = NEW.id_user;
  ELSIF (TG_OP = 'DELETE') THEN
    passphrase = OLD.passphrase_share;
    id_user = OLD.id_user;
  END IF;
  if passphrase IS NOT NULL THEN
    SELECT public.get_next_version_func(TG_TABLE_SCHEMA, id_user) INTO new_version;
    EXECUTE format('UPDATE %s SET version = %L WHERE passphrase_share = %L', album_table, new_version, passphrase);
  END IF;
  RETURN NULL;
END
$$;


ALTER FUNCTION public.share_permission_update_album_version_func() OWNER TO "SynologyPhotos";

--
-- Name: share_update_album_version_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.share_update_album_version_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  new_version bigint;
  album_table text;
BEGIN
  album_table = TG_TABLE_SCHEMA || '.album';
  IF (TG_OP = 'UPDATE') THEN
    IF (NEW.privacy_type != OLD.privacy_type OR NEW.modified_time != OLD.modified_time OR NEW.expired_time != OLD.expired_time OR NEW.hashed_password != OLD.hashed_password OR NEW.enable != OLD.enable) THEN
      SELECT public.get_next_version_func(TG_TABLE_SCHEMA, NEW.id_user) INTO new_version;
      EXECUTE format('UPDATE %s SET version = %L WHERE passphrase_share = %L', album_table, new_version, NEW.passphrase);
    END IF;
  END IF;
  RETURN NULL;
END
$$;


ALTER FUNCTION public.share_update_album_version_func() OWNER TO "SynologyPhotos";

--
-- Name: tag_update_unit_version_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.tag_update_unit_version_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  new_version bigint;
  unit_table text;
  id_user integer;
  id_unit integer;
BEGIN
  unit_table = TG_TABLE_SCHEMA || '.unit';
  IF (TG_OP = 'INSERT') THEN
    EXECUTE 'SELECT id_user FROM ' || unit_table || ' WHERE id = ' || NEW.id_unit INTO id_user;
    SELECT public.get_next_version_func(TG_TABLE_SCHEMA, id_user) INTO new_version;
    EXECUTE 'UPDATE ' || unit_table || ' SET version = ' || new_version || ' WHERE id = ' || NEW.id_unit;
  ELSIF (TG_OP = 'DELETE') THEN
    EXECUTE 'SELECT id_user FROM ' || unit_table || ' WHERE id = ' || OLD.id_unit INTO id_user;
    IF (id_user IS NULL) THEN
      RETURN NULL;
    END IF;
    SELECT public.get_next_version_func(TG_TABLE_SCHEMA, id_user) INTO new_version;
    EXECUTE 'UPDATE ' || unit_table || ' SET version = ' || new_version || ' WHERE id = ' || OLD.id_unit;
  END IF;
  RETURN NULL;
END
$$;


ALTER FUNCTION public.tag_update_unit_version_func() OWNER TO "SynologyPhotos";

--
-- Name: unit_update_condition_album_func(text, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.unit_update_condition_album_func(schema text, item_id integer) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  condition_album_table text;
  unit_table text;
  count integer;
  record RECORD;
BEGIN
  condition_album_table = schema || '.condition_album';
  unit_table = schema || '.unit';
  EXECUTE format('SELECT count(*) FROM %s WHERE id_item = %L', unit_table, item_id) INTO count;
  IF (count > 0) THEN
    FOR record IN EXECUTE format('SELECT * FROM %s WHERE cover = %L', condition_album_table, item_id) LOOP
      EXECUTE format('SELECT public.increase_album_version_func(%L, %s)', schema, record.id);
    END LOOP;
  ELSE
    FOR record IN EXECUTE format('SELECT * FROM %s WHERE cover = %L', condition_album_table, item_id) LOOP
      EXECUTE format('SELECT public.update_condition_album_cover_func(%L, %s, %L)', schema, record.id, item_id);
    END LOOP;
  END IF;
END
$$;


ALTER FUNCTION public.unit_update_condition_album_func(schema text, item_id integer) OWNER TO "SynologyPhotos";

--
-- Name: unit_update_id_item_func(text, integer, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.unit_update_id_item_func(schema text, item_id integer, new_item_id integer) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  many_item_has_many_normal_album_table text;
  album_array bigint[];
  album_id bigint;
  record RECORD;
BEGIN
  many_item_has_many_normal_album_table = schema || '.many_item_has_many_normal_album';
  EXECUTE format('SELECT array_agg(id_normal_album) FROM %s WHERE id_item = %L', many_item_has_many_normal_album_table, item_id) INTO album_array;
  IF (album_array IS NOT NULL) THEN
    FOREACH album_id IN ARRAY album_array LOOP
      EXECUTE format('SELECT * FROM %s WHERE id_normal_album = %L AND id_item = %L', many_item_has_many_normal_album_table, album_id, new_item_id) INTO record;
      IF (record IS NULL) THEN
        EXECUTE format('UPDATE %s SET id_item = %L WHERE id_normal_album = %L AND id_item = %L', many_item_has_many_normal_album_table, new_item_id, album_id, item_id);
      END IF;
    END LOOP;
  END IF;
END
$$;


ALTER FUNCTION public.unit_update_id_item_func(schema text, item_id integer, new_item_id integer) OWNER TO "SynologyPhotos";

--
-- Name: unit_update_normal_album_func(text, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.unit_update_normal_album_func(schema text, item_id integer) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  normal_album_table text;
  unit_table text;
  count integer;
  record RECORD;
BEGIN
  normal_album_table = schema || '.normal_album';
  unit_table = schema || '.unit';
  EXECUTE format('SELECT count(*) FROM %s WHERE id_item = %L', unit_table, item_id) INTO count;
  IF (count > 0) THEN
    FOR record IN EXECUTE format('SELECT * FROM %s WHERE cover = %L', normal_album_table, item_id) LOOP
      EXECUTE format('SELECT public.increase_album_version_func(%L, %s)', schema, record.id);
    END LOOP;
  ELSE
    FOR record IN EXECUTE format('SELECT * FROM %s WHERE cover = %L', normal_album_table, item_id) LOOP
      EXECUTE format('SELECT public.update_normal_album_cover_func(%L, %s, %L)', schema, record.id, item_id);
    END LOOP;
  END IF;
END
$$;


ALTER FUNCTION public.unit_update_normal_album_func(schema text, item_id integer) OWNER TO "SynologyPhotos";

--
-- Name: unset_person_table_read_only_top_down_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.unset_person_table_read_only_top_down_func() RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
BEGIN
  PERFORM public.drop_read_only_trigger_func('face');
  PERFORM public.drop_read_only_trigger_func('person_group');
  PERFORM public.drop_read_only_trigger_func('cluster');
  PERFORM public.drop_read_only_trigger_func('person');
END
$$;


ALTER FUNCTION public.unset_person_table_read_only_top_down_func() OWNER TO "SynologyPhotos";

--
-- Name: update_condition_album_cover_func(text, integer, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_condition_album_cover_func(schema text, album_id integer, old_item_id integer) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
condition_album_table  text;
condition_album_item_table text;
item_id integer;
BEGIN
  condition_album_table = schema || '.condition_album';
  condition_album_item_table = schema || '.condition_album_item_' || album_id;
  EXECUTE format('DELETE FROM %s WHERE id_item = %L', condition_album_item_table, old_item_id);
  EXECUTE format('SELECT id_item FROM %s LIMIT 1', condition_album_item_table) INTO item_id;
  IF item_id IS NULL THEN
    item_id = 0;
  END IF;
  EXECUTE format('UPDATE %s SET cover = %L, need_update_item = true WHERE id = %L', condition_album_table, item_id, album_id);
END
$$;


ALTER FUNCTION public.update_condition_album_cover_func(schema text, album_id integer, old_item_id integer) OWNER TO "SynologyPhotos";

--
-- Name: update_condition_album_time_trigger_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_condition_album_time_trigger_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  unit_time bigint;
  condition_album_table text;
  max_time bigint;
  min_time bigint;
  record RECORD;
BEGIN
  unit_time = OLD.takentime;
  condition_album_table = TG_TABLE_SCHEMA || '.condition_album';
  FOR record IN EXECUTE format('SELECT * FROM %s WHERE start_time = %L OR end_time = %L', condition_album_table, unit_time, unit_time) LOOP
    EXECUTE format('SELECT max, min FROM public.get_unit_takentime_by_condition_album(%L)', record.id) INTO max_time, min_time;
    EXECUTE 'UPDATE ' || condition_album_table || COALESCE(' SET start_time = ' || min_time, ' SET start_time = NULL') || COALESCE(', end_time = ' || max_time, ', end_time = NULL') || ' WHERE id = ' || record.id;
  END LOOP;
  RETURN NULL;
END;
$$;


ALTER FUNCTION public.update_condition_album_time_trigger_func() OWNER TO "SynologyPhotos";

--
-- Name: update_condition_album_version_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_condition_album_version_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  new_version bigint;
BEGIN
  IF (TG_OP = 'INSERT' or
      (TG_OP = 'UPDATE' AND
        (
          NEW.condition::text != OLD.condition::text
          OR NEW.item_count != OLD.item_count
          OR NEW.cover != OLD.cover
          OR NEW.name != OLD.name
          OR NEW.shared != OLD.shared
          OR NEW.sort_by != OLD.sort_by
          OR NEW.sort_direction != OLD.sort_direction
          OR NEW.passphrase_share != OLD.passphrase_share
        )
      )
     ) THEN
    SELECT public.get_next_version_func(TG_TABLE_SCHEMA, NEW.id_user) INTO new_version;
    NEW.version = new_version;
  END IF;
  RETURN NEW;
END
$$;


ALTER FUNCTION public.update_condition_album_version_func() OWNER TO "SynologyPhotos";

--
-- Name: update_face_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_face_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  custom_cover bool;
  cover integer;
BEGIN
  IF (OLD.id_person IS NOT NULL) THEN
    EXECUTE format('SELECT cover FROM %I.person WHERE id = %s', TG_TABLE_SCHEMA, OLD.id_person) INTO cover;
    IF (cover = OLD.id) THEN
      PERFORM public.update_person_best_cover(OLD.id_person, TG_TABLE_SCHEMA);
    END IF;
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION public.update_face_func() OWNER TO "SynologyPhotos";

--
-- Name: update_filter_after_many_unit_has_many_concept_delete_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_filter_after_many_unit_has_many_concept_delete_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  DELETE FROM public.filter
  WHERE id_unit = OLD.id_unit AND id_user = OLD.id_user AND filter_type = 'concept';
  RETURN NULL;
END
$$;


ALTER FUNCTION public.update_filter_after_many_unit_has_many_concept_delete_func() OWNER TO "SynologyPhotos";

--
-- Name: update_filter_with_conflict_delete(integer, integer, integer, integer, text); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_filter_with_conflict_delete(p_old_id_filter integer, p_new_id_filter integer, p_id_user integer, p_max_id_unit integer, p_filter_type text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- remove conflict rows first
    DELETE FROM filter f
    USING filter conflict
    WHERE
        f.filter_type = p_filter_type
        AND f.id_user = p_id_user
        AND f.id_filter = p_old_id_filter
        AND f.id_unit <= p_max_id_unit
        AND conflict.id_unit     = f.id_unit
        AND conflict.id_filter   = p_new_id_filter
        AND conflict.filter_type = f.filter_type
        AND conflict.id_user     = f.id_user
        AND conflict.ctid <> f.ctid;
    UPDATE filter
    SET id_filter = p_new_id_filter
    WHERE
        filter_type = p_filter_type
        AND id_user = p_id_user
        AND id_filter = p_old_id_filter
        AND id_unit <= p_max_id_unit;
END;
$$;


ALTER FUNCTION public.update_filter_with_conflict_delete(p_old_id_filter integer, p_new_id_filter integer, p_id_user integer, p_max_id_unit integer, p_filter_type text) OWNER TO "SynologyPhotos";

--
-- Name: update_many_unit_has_many_administrative_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_many_unit_has_many_administrative_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  many_unit_has_many_administrative_table text;
  filter_type text;
BEGIN
  filter_type = COALESCE(NEW.filter_type, OLD.filter_type);
  IF (filter_type = 'administrative') THEN
    many_unit_has_many_administrative_table = TG_TABLE_SCHEMA || '.many_unit_has_many_administrative';
    IF (TG_OP = 'INSERT') THEN
      EXECUTE format('INSERT INTO %s (id_unit, id_administrative, id_user) VALUES (%L, %L, %L) ON CONFLICT (id_unit, id_administrative) DO NOTHING', many_unit_has_many_administrative_table, NEW.id_unit, NEW.id_filter, NEW.id_user);
    ELSIF (TG_OP = 'DELETE') THEN
      EXECUTE format('DELETE FROM %s WHERE id_unit = %L and id_administrative = %L', many_unit_has_many_administrative_table, OLD.id_unit, OLD.id_filter);
    ELSIF (TG_OP = 'UPDATE') THEN
      EXECUTE format('UPDATE %s SET id_administrative = %L WHERE id_unit = %L AND id_user = %L', many_unit_has_many_administrative_table, NEW.id_filter, NEW.id_unit, NEW.id_user);
    END IF;
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION public.update_many_unit_has_many_administrative_func() OWNER TO "SynologyPhotos";

--
-- Name: update_many_unit_has_many_person_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_many_unit_has_many_person_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  many_unit_has_many_person_table text;
BEGIN
  IF (NEW.filter_type = 'person' OR OLD.filter_type = 'person') THEN
    many_unit_has_many_person_table = TG_TABLE_SCHEMA || '.many_unit_has_many_person';
    IF (TG_OP = 'INSERT') THEN
      EXECUTE format('INSERT INTO %s (id_unit, id_person, id_user) VALUES (%L, %L, %L) ON CONFLICT (id_unit, id_person) DO NOTHING', many_unit_has_many_person_table, NEW.id_unit, NEW.id_filter, NEW.id_user);
    ELSIF (TG_OP = 'DELETE') THEN
      EXECUTE format('DELETE FROM %s WHERE id_unit = %L and id_person = %L', many_unit_has_many_person_table, OLD.id_unit, OLD.id_filter);
    ELSIF (TG_OP = 'UPDATE') THEN
      EXECUTE format('UPDATE %s SET id_person = %L WHERE id_unit = %L AND id_user = %L AND id_person = %L', many_unit_has_many_person_table, NEW.id_filter, NEW.id_unit, NEW.id_user, OLD.id_filter);
    END IF;
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION public.update_many_unit_has_many_person_func() OWNER TO "SynologyPhotos";

--
-- Name: update_normal_album_cover_func(text, integer, integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_normal_album_cover_func(schema text, album_id integer, old_item_id integer) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
many_item_has_many_normal_album_table text;
normal_album_table  text;
item_id integer;
BEGIN
  many_item_has_many_normal_album_table = schema || '.many_item_has_many_normal_album';
  normal_album_table = schema || '.normal_album';
  EXECUTE format('SELECT id_item FROM %s WHERE id_normal_album = %L AND id_item != %L', many_item_has_many_normal_album_table, album_id, old_item_id) INTO item_id;
  IF item_id IS NULL THEN
    item_id = 0;
  END IF;
  EXECUTE format('UPDATE %s SET cover = %L WHERE id = %L', normal_album_table, item_id, album_id);
END
$$;


ALTER FUNCTION public.update_normal_album_cover_func(schema text, album_id integer, old_item_id integer) OWNER TO "SynologyPhotos";

--
-- Name: update_normal_album_time_trigger_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_normal_album_time_trigger_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  id_item integer;
  many_table text;
  normal_album_table text;
  max_time bigint;
  min_time bigint;
  record RECORD;
BEGIN
  id_item  = OLD.id_item;
  normal_album_table = TG_TABLE_SCHEMA || '.normal_album';
  many_table = TG_TABLE_SCHEMA || '.many_item_has_many_normal_album';
  FOR record IN EXECUTE format('SELECT * FROM %s WHERE id_item = %L', many_table, id_item) LOOP
    EXECUTE format('SELECT max, min FROM public.get_unit_takentime_by_album(%L, %L)', record.id_normal_album, TG_TABLE_SCHEMA) INTO max_time, min_time;
    EXECUTE 'UPDATE ' || normal_album_table || COALESCE(' SET start_time = ' || min_time, ' SET start_time = NULL') || COALESCE(', end_time = ' || max_time, ', end_time = NULL') || ' WHERE id = ' || record.id_normal_album;
  END LOOP;
  RETURN NULL;
END;
$$;


ALTER FUNCTION public.update_normal_album_time_trigger_func() OWNER TO "SynologyPhotos";

--
-- Name: update_normal_album_version_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_normal_album_version_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  next_version bigint;
BEGIN
  IF (TG_OP = 'INSERT' or (TG_OP = 'UPDATE' AND (NEW.item_count != OLD.item_count OR NEW.cover != OLD.cover OR NEW.name != OLD.name OR NEW.shared != OLD.shared OR NEW.sort_by != OLD.sort_by OR NEW.sort_direction != OLD.sort_direction OR NEW.passphrase_share != OLD.passphrase_share))) THEN
       SELECT public.get_next_version_func(TG_TABLE_SCHEMA, NEW.id_user) INTO next_version;
       NEW.version = next_version;
  END IF;
  RETURN NEW;
END
$$;


ALTER FUNCTION public.update_normal_album_version_func() OWNER TO "SynologyPhotos";

--
-- Name: update_one_filter_has_many_unit_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_one_filter_has_many_unit_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  one_filter_has_many_unit_table text;
  target_column text;
  filter_type text;
  is_major boolean;
BEGIN
  filter_type = COALESCE(NEW.filter_type, OLD.filter_type);
  IF (filter_type IN (
    'aperture',
    'camera',
    'exposure_time',
    'flash',
    'focal_length',
    'folder',
    'iso',
    'item_type',
    'lens',
    'takentime',
    'rating'
  ))
  THEN
    one_filter_has_many_unit_table = TG_TABLE_SCHEMA || '.one_filter_has_many_unit';
    target_column = 'id_' || filter_type;
    IF (TG_OP = 'INSERT') THEN
      EXECUTE format('SELECT is_major FROM unit WHERE unit.id = %L', NEW.id_unit) INTO is_major;
      EXECUTE format('INSERT INTO %s (id_unit, %s, id_user, is_major) VALUES (%L, %L, %L, %L) ON CONFLICT (id_unit) DO UPDATE SET %s = %L', one_filter_has_many_unit_table, target_column, NEW.id_unit, NEW.id_filter, NEW.id_user, is_major, target_column, NEW.id_filter);
    ELSIF (TG_OP = 'DELETE') THEN
      IF (filter_type IN ('rating')) THEN
        EXECUTE format('UPDATE %s SET %s = 0 WHERE id_unit = %L', one_filter_has_many_unit_table, target_column, OLD.id_unit);
      ELSE
        EXECUTE format('UPDATE %s SET %s = NULL WHERE id_unit = %L', one_filter_has_many_unit_table, target_column, OLD.id_unit);
      END IF;
    ELSIF (TG_OP = 'UPDATE') THEN
      EXECUTE format('UPDATE %s SET %s = %L WHERE id_unit = %L AND id_user = %L', one_filter_has_many_unit_table, target_column, NEW.id_filter, NEW.id_unit, NEW.id_user);
    END IF;
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION public.update_one_filter_has_many_unit_func() OWNER TO "SynologyPhotos";

--
-- Name: update_one_filter_has_many_unit_is_major_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_one_filter_has_many_unit_is_major_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  one_filter_has_many_unit_table text;
BEGIN
  one_filter_has_many_unit_table = TG_TABLE_SCHEMA || '.one_filter_has_many_unit';
  EXECUTE format('UPDATE %s SET is_major = %L WHERE id_unit = %L AND id_user = %L', one_filter_has_many_unit_table, NEW.is_major, OLD.id, OLD.id_user);
  RETURN NULL;
END;
$$;


ALTER FUNCTION public.update_one_filter_has_many_unit_is_major_func() OWNER TO "SynologyPhotos";

--
-- Name: update_person_best_cover(integer, text); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_person_best_cover(id_person integer, schema text) RETURNS void
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
  cover integer;
BEGIN
  EXECUTE format('SELECT id FROM %I.face WHERE id_person = %s and id_unit != 0 ORDER BY score DESC LIMIT 1',
    schema, id_person) INTO cover;
  IF (cover IS NOT NULL) THEN
    EXECUTE format('UPDATE %I.person SET cover = %s WHERE id = %s', schema, cover, id_person);
  END IF;
END;
$$;


ALTER FUNCTION public.update_person_best_cover(id_person integer, schema text) OWNER TO "SynologyPhotos";

--
-- Name: update_similar_group_top_pick_func(integer); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_similar_group_top_pick_func(group_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  new_top_pick integer;
BEGIN
  new_top_pick := (
    SELECT i.id
    FROM item i
    JOIN unit u ON i.id = u.id_item
    WHERE i.id_similar_group = group_id
    ORDER BY (u.resolution->>'height')::integer * (u.resolution->>'width')::integer DESC, u.filesize DESC, u.takentime DESC
    LIMIT 1
  );
  UPDATE similar_group
  SET
    top_pick = new_top_pick,
    update_at = round(extract(epoch FROM now()) * 1000)
  WHERE
    id = group_id;
  UPDATE item
  SET
    is_similar_top_pick = true
  WHERE
    id = new_top_pick;
END;
$$;


ALTER FUNCTION public.update_similar_group_top_pick_func(group_id integer) OWNER TO "SynologyPhotos";

--
-- Name: update_similar_timeline_after_item_update_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_similar_timeline_after_item_update_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.similar_timeline
  SET
    id_similar_group = NEW.id_similar_group
  WHERE id_item = NEW.id;
  IF (NEW.id_similar_group IS NULL) THEN
     UPDATE public.similar_timeline
      SET
        similar_group_item_count = NULL
      WHERE id_item = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_similar_timeline_after_item_update_func() OWNER TO "SynologyPhotos";

--
-- Name: update_similar_timeline_after_similar_group_update_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_similar_timeline_after_similar_group_update_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.similar_timeline
  SET
    similar_group_item_count = NEW.item_count
  WHERE id_similar_group = NEW.id;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_similar_timeline_after_similar_group_update_func() OWNER TO "SynologyPhotos";

--
-- Name: update_similar_timeline_after_unit_insert_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_similar_timeline_after_unit_insert_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO public.similar_timeline (id_unit, id_item, id_user, takentime)
  SELECT
    NEW.id,
    NEW.id_item,
    NEW.id_user,
    NEW.takentime
  FROM item
  WHERE NEW.id_item = item.id
  AND item.is_similar_top_pick is NOT FALSE
  ON CONFLICT (id_unit, id_item, id_user)
  DO UPDATE SET
    takentime = EXCLUDED.takentime;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_similar_timeline_after_unit_insert_func() OWNER TO "SynologyPhotos";

--
-- Name: update_tag_ref_count_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_tag_ref_count_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
     tag_id integer;
     check_id integer;
     ref_count integer;
     general_tag_table text;
      BEGIN
          general_tag_table = TG_TABLE_SCHEMA || '.general_tag';
          IF (TG_OP = 'INSERT') THEN
              tag_id = NEW.id_general_tag;
              EXECUTE 'UPDATE ' || general_tag_table || ' SET count = COALESCE(count, 0) + 1 WHERE id = ' || tag_id;
          ELSIF (TG_OP = 'UPDATE') THEN
               tag_id = NEW.id_general_tag;
               check_id = OLD.id_general_tag;
              EXECUTE 'UPDATE ' || general_tag_table || ' SET count = COALESCE(count, 0) + 1 WHERE id = ' || tag_id;
              EXECUTE 'UPDATE ' || general_tag_table || ' SET count = COALESCE(count, 0) - 1 WHERE id = ' || check_id;
          ELSIF (TG_OP = 'DELETE') THEN
              check_id = OLD.id_general_tag;
              EXECUTE 'UPDATE ' || general_tag_table || ' SET count = COALESCE(count, 0) - 1 WHERE id = ' || check_id;
          END IF;
          IF check_id IS NOT NULL THEN
             EXECUTE 'SELECT count  FROM '|| general_tag_table || ' WHERE id = ' || check_id INTO ref_count;
             IF (ref_count  <=0 ) THEN
              EXECUTE 'DELETE FROM ' || general_tag_table || ' WHERE id = ' || check_id;
              END IF;
          END IF;
          RETURN NULL;
      END;
$$;


ALTER FUNCTION public.update_tag_ref_count_func() OWNER TO "SynologyPhotos";

--
-- Name: update_unit_version_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_unit_version_func() RETURNS trigger
    LANGUAGE plpgsql COST 1
    AS $$
DECLARE
    new_version bigint;
BEGIN
    IF (TG_OP = 'INSERT') THEN
        SELECT public.get_next_version_func(TG_TABLE_SCHEMA, NEW.id_user) INTO new_version;
        NEW.version = new_version;
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        IF (NEW.index_stage != OLD.index_stage OR
            NEW.filename != OLD.filename OR
            NEW.id_folder != OLD.id_folder OR
            NEW.id_user != OLD.id_user OR
            NEW.takentime != OLD.takentime OR
            NEW.id_geocoding != OLD.id_geocoding OR
            NEW.mtime != OLD.mtime OR
            NEW.cache_key != OLD.cache_key) THEN
           SELECT public.get_next_version_func(TG_TABLE_SCHEMA, NEW.id_user) INTO new_version;
           NEW.version = new_version;
        END IF;
        RETURN NEW;
    END IF;
    RETURN NULL;
END
$$;


ALTER FUNCTION public.update_unit_version_func() OWNER TO "SynologyPhotos";

--
-- Name: update_user_flag_after_delete_item_update_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_user_flag_after_delete_item_update_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO public.user_flag (id_user, flag, value)
  VALUES
    (NEW.id_user, 'need_recount_concept_item', 'true'),
    (NEW.id_user, 'need_recount_person_item', 'true')
  ON CONFLICT (id_user, flag) DO UPDATE SET value = 'true';
  RETURN NULL;
END
$$;


ALTER FUNCTION public.update_user_flag_after_delete_item_update_func() OWNER TO "SynologyPhotos";

--
-- Name: update_user_flag_after_live_photo_update_func(); Type: FUNCTION; Schema: public; Owner: SynologyPhotos
--

CREATE FUNCTION public.update_user_flag_after_live_photo_update_func() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  affected_id_user integer;
BEGIN
  IF (TG_OP = 'INSERT') THEN
    SELECT DISTINCT n.id_user from new_table n where n.item_type=3 INTO affected_id_user;
  ELSIF (TG_OP = 'UPDATE') THEN
    SELECT DISTINCT n.id_user
      FROM new_table n
      JOIN old_table o ON n.id_user = o.id_user
      WHERE n.is_major <> o.is_major
      INTO affected_id_user;
  END IF;
  IF (affected_id_user IS NULL) THEN
    RETURN NULL;
  END IF;
  INSERT INTO public.user_flag (id_user, flag, value)
  VALUES
   (affected_id_user, 'need_recount_concept_item', 'true'),
   (affected_id_user, 'need_recount_person_item', 'true')
  ON CONFLICT (id_user, flag) DO UPDATE SET value = 'true';
  RETURN NULL;
END
$$;


ALTER FUNCTION public.update_user_flag_after_live_photo_update_func() OWNER TO "SynologyPhotos";

SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: acl_permission; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.acl_permission (
    fullpath text NOT NULL,
    permission text NOT NULL,
    type smallint NOT NULL,
    id_type integer NOT NULL
);


ALTER TABLE public.acl_permission OWNER TO "SynologyPhotos";

--
-- Name: activity; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.activity (
    id integer NOT NULL,
    id_user integer NOT NULL,
    id_album integer NOT NULL,
    type smallint NOT NULL,
    create_time bigint NOT NULL
);


ALTER TABLE public.activity OWNER TO "SynologyPhotos";

--
-- Name: activity_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.activity_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.activity_id_seq OWNER TO "SynologyPhotos";

--
-- Name: activity_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.activity_id_seq OWNED BY public.activity.id;


--
-- Name: address; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.address (
    id integer NOT NULL,
    lang smallint NOT NULL,
    admin smallint NOT NULL,
    level integer NOT NULL,
    value text NOT NULL,
    id_unit integer,
    id_user integer NOT NULL
);


ALTER TABLE public.address OWNER TO "SynologyPhotos";

--
-- Name: address_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.address_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.address_id_seq OWNER TO "SynologyPhotos";

--
-- Name: address_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.address_id_seq OWNED BY public.address.id;


--
-- Name: administrative; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.administrative (
    id integer NOT NULL,
    value text NOT NULL
);


ALTER TABLE public.administrative OWNER TO "SynologyPhotos";

--
-- Name: administrative_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.administrative_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.administrative_id_seq OWNER TO "SynologyPhotos";

--
-- Name: administrative_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.administrative_id_seq OWNED BY public.administrative.id;


--
-- Name: album; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.album (
    id integer NOT NULL,
    id_user integer NOT NULL,
    name text NOT NULL,
    type smallint NOT NULL,
    shared boolean DEFAULT false NOT NULL,
    create_time bigint NOT NULL,
    cover integer DEFAULT 0 NOT NULL,
    sort_by smallint DEFAULT 0 NOT NULL,
    sort_direction smallint DEFAULT 0 NOT NULL,
    normalized_name text DEFAULT ''::text NOT NULL,
    version bigint NOT NULL,
    passphrase_share text,
    item_count integer,
    start_time bigint,
    end_time bigint,
    name_for_sort text DEFAULT ''::text NOT NULL
);


ALTER TABLE public.album OWNER TO "SynologyPhotos";

--
-- Name: album_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.album_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.album_id_seq OWNER TO "SynologyPhotos";

--
-- Name: album_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.album_id_seq OWNED BY public.album.id;


--
-- Name: normal_album; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.normal_album (
    cant_migrate_condition json,
    condition json,
    status smallint DEFAULT 0 NOT NULL,
    start_time bigint,
    end_time bigint
)
INHERITS (public.album);


ALTER TABLE public.normal_album OWNER TO "SynologyPhotos";

--
-- Name: share; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.share (
    passphrase text NOT NULL,
    privacy_type smallint DEFAULT 0 NOT NULL,
    modified_time bigint DEFAULT 0 NOT NULL,
    id_user integer NOT NULL,
    expired_time bigint NOT NULL,
    hashed_password text NOT NULL,
    enable boolean NOT NULL,
    type smallint NOT NULL
);


ALTER TABLE public.share OWNER TO "SynologyPhotos";

--
-- Name: album_with_share_info_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.album_with_share_info_view AS
 SELECT album.id,
    album.id_user,
    album.name,
    album.type,
    album.create_time,
    album.start_time,
    share.privacy_type,
    share.enable,
    album.passphrase_share,
    normal_album.status,
    album.name_for_sort
   FROM ((public.album
     LEFT JOIN public.share ON ((album.passphrase_share = share.passphrase)))
     LEFT JOIN public.normal_album ON ((album.passphrase_share = normal_album.passphrase_share)));


ALTER TABLE public.album_with_share_info_view OWNER TO "SynologyPhotos";

--
-- Name: aperture; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.aperture (
    id integer NOT NULL,
    name text NOT NULL,
    normalized_name text NOT NULL
);


ALTER TABLE public.aperture OWNER TO "SynologyPhotos";

--
-- Name: aperture_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.aperture_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.aperture_id_seq OWNER TO "SynologyPhotos";

--
-- Name: aperture_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.aperture_id_seq OWNED BY public.aperture.id;


--
-- Name: async_db_migration_task; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.async_db_migration_task (
    id integer NOT NULL,
    id_user integer NOT NULL,
    target_version integer NOT NULL,
    payload json
);


ALTER TABLE public.async_db_migration_task OWNER TO "SynologyPhotos";

--
-- Name: async_db_migration_task_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.async_db_migration_task_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.async_db_migration_task_id_seq OWNER TO "SynologyPhotos";

--
-- Name: async_db_migration_task_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.async_db_migration_task_id_seq OWNED BY public.async_db_migration_task.id;


--
-- Name: background_task; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.background_task (
    id integer NOT NULL,
    operation smallint NOT NULL,
    status smallint NOT NULL,
    created_time bigint NOT NULL,
    modified_time bigint NOT NULL,
    total bigint NOT NULL,
    completion bigint NOT NULL,
    error bigint NOT NULL,
    id_user integer NOT NULL,
    extra_info text,
    payload json,
    skip bigint DEFAULT 0 NOT NULL,
    overwrite bigint DEFAULT 0 NOT NULL
);


ALTER TABLE public.background_task OWNER TO "SynologyPhotos";

--
-- Name: background_task_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.background_task_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.background_task_id_seq OWNER TO "SynologyPhotos";

--
-- Name: background_task_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.background_task_id_seq OWNED BY public.background_task.id;


--
-- Name: burst_additional; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.burst_additional (
    grouping_key text NOT NULL,
    sequence bigint NOT NULL,
    id_unit integer,
    id_user integer NOT NULL
);


ALTER TABLE public.burst_additional OWNER TO "SynologyPhotos";

--
-- Name: camera; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.camera (
    id integer NOT NULL,
    name text NOT NULL,
    normalized_name text NOT NULL
);


ALTER TABLE public.camera OWNER TO "SynologyPhotos";

--
-- Name: camera_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.camera_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.camera_id_seq OWNER TO "SynologyPhotos";

--
-- Name: camera_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.camera_id_seq OWNED BY public.camera.id;


--
-- Name: check_album_task; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.check_album_task (
    id integer NOT NULL,
    id_user integer DEFAULT 0 NOT NULL,
    id_group integer DEFAULT 0 NOT NULL,
    id_folder integer DEFAULT 0 NOT NULL,
    status smallint DEFAULT 0 NOT NULL
);


ALTER TABLE public.check_album_task OWNER TO "SynologyPhotos";

--
-- Name: check_album_task_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.check_album_task_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.check_album_task_id_seq OWNER TO "SynologyPhotos";

--
-- Name: check_album_task_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.check_album_task_id_seq OWNED BY public.check_album_task.id;


--
-- Name: cluster; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.cluster (
    id integer NOT NULL,
    id_person integer,
    id_user integer NOT NULL,
    is_manual boolean DEFAULT false NOT NULL
);


ALTER TABLE public.cluster OWNER TO "SynologyPhotos";

--
-- Name: cluster_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.cluster_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.cluster_id_seq OWNER TO "SynologyPhotos";

--
-- Name: cluster_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.cluster_id_seq OWNED BY public.cluster.id;


--
-- Name: concept; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.concept (
    id integer NOT NULL,
    stem text NOT NULL,
    hidden boolean DEFAULT false NOT NULL,
    display_threshold smallint NOT NULL,
    confidence_threshold numeric(5,4),
    parent integer[] NOT NULL,
    sort_index integer DEFAULT '-1'::integer NOT NULL
);


ALTER TABLE public.concept OWNER TO "SynologyPhotos";

--
-- Name: concept_album_additional; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.concept_album_additional (
    id_concept integer NOT NULL,
    id_user integer NOT NULL,
    item_count bigint NOT NULL,
    custom_cover_id_unit integer,
    visibility_status smallint DEFAULT 0 NOT NULL
);


ALTER TABLE public.concept_album_additional OWNER TO "SynologyPhotos";

--
-- Name: concept_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.concept_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.concept_id_seq OWNER TO "SynologyPhotos";

--
-- Name: concept_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.concept_id_seq OWNED BY public.concept.id;


--
-- Name: concept_rawdata; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.concept_rawdata (
    id_unit integer NOT NULL,
    result json NOT NULL,
    need_migrate boolean DEFAULT false NOT NULL,
    version integer NOT NULL,
    id_user integer NOT NULL
);


ALTER TABLE public.concept_rawdata OWNER TO "SynologyPhotos";

--
-- Name: concept_synonym; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.concept_synonym (
    lang smallint NOT NULL,
    id_concept integer NOT NULL,
    synonym text NOT NULL,
    priority smallint NOT NULL,
    normalized_synonym text DEFAULT ''::text NOT NULL
);


ALTER TABLE public.concept_synonym OWNER TO "SynologyPhotos";

--
-- Name: concept_threshold; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.concept_threshold (
    id_concept integer NOT NULL,
    version smallint NOT NULL,
    confidence_threshold numeric(5,4) NOT NULL
);


ALTER TABLE public.concept_threshold OWNER TO "SynologyPhotos";

--
-- Name: concept_timeline_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.concept_timeline_view AS
SELECT
    NULL::integer AS id_item,
    NULL::integer AS id_user,
    NULL::smallint AS item_type,
    NULL::smallint AS unit_type,
    NULL::integer AS id_unit,
    NULL::integer[] AS id_concept,
    NULL::bigint AS takentime;


ALTER TABLE public.concept_timeline_view OWNER TO "SynologyPhotos";

--
-- Name: condition_album; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.condition_album (
    condition json,
    need_update_item boolean DEFAULT false NOT NULL,
    item_update_version bigint DEFAULT 0 NOT NULL
)
INHERITS (public.album);


ALTER TABLE public.condition_album OWNER TO "SynologyPhotos";

--
-- Name: config; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.config (
    key text NOT NULL,
    value text NOT NULL
);


ALTER TABLE public.config OWNER TO "SynologyPhotos";

--
-- Name: convert_thumbnail_allocation; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.convert_thumbnail_allocation (
    session_id text NOT NULL,
    sent_to_client boolean NOT NULL,
    id integer NOT NULL,
    id_user integer NOT NULL,
    filename text NOT NULL,
    unit_type smallint NOT NULL,
    item_type smallint NOT NULL,
    status smallint NOT NULL,
    lower_extension text NOT NULL,
    thumbnail_type integer[] NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.convert_thumbnail_allocation OWNER TO "SynologyPhotos";

--
-- Name: delete_album; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.delete_album (
    id_normal_album integer NOT NULL,
    id_user integer NOT NULL,
    version bigint NOT NULL
);


ALTER TABLE public.delete_album OWNER TO "SynologyPhotos";

--
-- Name: delete_condition_album; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.delete_condition_album (
    id_condition_album integer NOT NULL,
    id_user integer NOT NULL,
    version bigint NOT NULL
);


ALTER TABLE public.delete_condition_album OWNER TO "SynologyPhotos";

--
-- Name: delete_item; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.delete_item (
    id_item integer NOT NULL,
    id_user integer NOT NULL,
    version bigint NOT NULL,
    reason integer DEFAULT 0 NOT NULL
);


ALTER TABLE public.delete_item OWNER TO "SynologyPhotos";

--
-- Name: dsm_group; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.dsm_group (
    gid bigint NOT NULL,
    name text NOT NULL
);


ALTER TABLE public.dsm_group OWNER TO "SynologyPhotos";

--
-- Name: dsm_user; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.dsm_user (
    uid bigint NOT NULL,
    name text NOT NULL
);


ALTER TABLE public.dsm_user OWNER TO "SynologyPhotos";

--
-- Name: exposure_time; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.exposure_time (
    id integer NOT NULL,
    name text NOT NULL,
    normalized_name text NOT NULL
);


ALTER TABLE public.exposure_time OWNER TO "SynologyPhotos";

--
-- Name: exposure_time_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.exposure_time_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.exposure_time_id_seq OWNER TO "SynologyPhotos";

--
-- Name: exposure_time_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.exposure_time_id_seq OWNED BY public.exposure_time.id;


--
-- Name: face; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.face (
    id integer NOT NULL,
    id_user integer NOT NULL,
    bounding_box json NOT NULL,
    landmark json,
    feature bytea,
    picture oid,
    score integer NOT NULL,
    id_unit integer,
    ref_id_unit integer NOT NULL,
    id_person_group integer,
    id_person integer,
    is_manual boolean DEFAULT false NOT NULL
);


ALTER TABLE public.face OWNER TO "SynologyPhotos";

--
-- Name: face_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.face_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.face_id_seq OWNER TO "SynologyPhotos";

--
-- Name: face_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.face_id_seq OWNED BY public.face.id;


--
-- Name: favorite_timeline; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.favorite_timeline (
    id_item integer NOT NULL,
    id_user integer NOT NULL,
    item_type integer NOT NULL,
    unit_type integer NOT NULL,
    id_unit integer NOT NULL,
    id_favorite_user integer[] NOT NULL,
    takentime bigint DEFAULT 0 NOT NULL
);


ALTER TABLE public.favorite_timeline OWNER TO "SynologyPhotos";

--
-- Name: file_operation_error; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.file_operation_error (
    id_task integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer NOT NULL,
    reason smallint NOT NULL
);


ALTER TABLE public.file_operation_error OWNER TO "SynologyPhotos";

--
-- Name: file_operation_task; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.file_operation_task (
    id_task integer NOT NULL,
    target_folder_id integer NOT NULL,
    policy smallint NOT NULL,
    id_user integer NOT NULL,
    id_item integer[] NOT NULL,
    id_folder integer[] NOT NULL,
    target_folder_id_user integer NOT NULL
);


ALTER TABLE public.file_operation_task OWNER TO "SynologyPhotos";

--
-- Name: filter; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.filter (
    id_unit integer NOT NULL,
    id_filter integer NOT NULL,
    filter_type text NOT NULL,
    id_user integer NOT NULL
);


ALTER TABLE public.filter OWNER TO "SynologyPhotos";

--
-- Name: focal_length; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.focal_length (
    id integer NOT NULL,
    name text NOT NULL,
    normalized_name text NOT NULL
);


ALTER TABLE public.focal_length OWNER TO "SynologyPhotos";

--
-- Name: focal_length_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.focal_length_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.focal_length_id_seq OWNER TO "SynologyPhotos";

--
-- Name: focal_length_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.focal_length_id_seq OWNED BY public.focal_length.id;


--
-- Name: folder; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.folder (
    id integer NOT NULL,
    id_user integer NOT NULL,
    name text NOT NULL,
    parent integer NOT NULL,
    name_for_sort text DEFAULT ''::text NOT NULL,
    permission text,
    mtime bigint DEFAULT 0 NOT NULL,
    passphrase_share text,
    shared boolean NOT NULL,
    sort_by smallint DEFAULT 0 NOT NULL,
    sort_direction smallint DEFAULT 0 NOT NULL,
    permission_parent integer DEFAULT 0 NOT NULL,
    name_for_search text DEFAULT ''::text NOT NULL,
    normalized_name text DEFAULT ''::text NOT NULL
);


ALTER TABLE public.folder OWNER TO "SynologyPhotos";

--
-- Name: folder_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.folder_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.folder_id_seq OWNER TO "SynologyPhotos";

--
-- Name: folder_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.folder_id_seq OWNED BY public.folder.id;


--
-- Name: folder_operation_error; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.folder_operation_error (
    id_task integer NOT NULL,
    target_id integer NOT NULL,
    reason smallint NOT NULL
);


ALTER TABLE public.folder_operation_error OWNER TO "SynologyPhotos";

--
-- Name: folder_operation_task; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.folder_operation_task (
    id_folder integer NOT NULL,
    id_task integer NOT NULL
);


ALTER TABLE public.folder_operation_task OWNER TO "SynologyPhotos";

--
-- Name: unit; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.unit (
    id integer NOT NULL,
    id_user integer NOT NULL,
    type smallint DEFAULT 0 NOT NULL,
    item_type smallint DEFAULT 0 NOT NULL,
    filename text NOT NULL,
    filesize bigint DEFAULT 0 NOT NULL,
    createtime bigint DEFAULT 0 NOT NULL,
    mtime bigint DEFAULT 0 NOT NULL,
    takentime bigint DEFAULT 0 NOT NULL,
    duplicate_hash text NOT NULL,
    cache_key text NOT NULL,
    resolution json NOT NULL,
    index_stage smallint NOT NULL,
    version bigint NOT NULL,
    id_geocoding integer,
    id_item integer NOT NULL,
    mobile_cache_mtime bigint DEFAULT 0 NOT NULL,
    reindex_flag smallint DEFAULT 0 NOT NULL,
    normalized_filename text DEFAULT ''::text NOT NULL,
    is_major boolean NOT NULL,
    id_folder integer NOT NULL,
    name_for_sort text DEFAULT ''::text NOT NULL,
    index_version integer DEFAULT 1 NOT NULL
);


ALTER TABLE public.unit OWNER TO "SynologyPhotos";

--
-- Name: folder_timeline_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.folder_timeline_view AS
 SELECT u.id_item,
    u.id_user,
    u.item_type,
    u.type AS unit_type,
    u.id AS id_unit,
    u.id_folder,
    u.takentime,
    u.filesize,
    u.normalized_filename,
    u.name_for_sort
   FROM public.folder f,
    public.unit u
  WHERE ((f.id = u.id_folder) AND (u.id_user = f.id_user) AND (u.is_major = true));


ALTER TABLE public.folder_timeline_view OWNER TO "SynologyPhotos";

--
-- Name: general_tag; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.general_tag (
    id integer NOT NULL,
    id_user integer NOT NULL,
    name text NOT NULL,
    count integer DEFAULT 0 NOT NULL,
    normalized_name text DEFAULT ''::text NOT NULL,
    name_for_sort text DEFAULT ''::text NOT NULL
);


ALTER TABLE public.general_tag OWNER TO "SynologyPhotos";

--
-- Name: many_unit_has_many_general_tag; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.many_unit_has_many_general_tag (
    id_unit integer NOT NULL,
    id_general_tag integer NOT NULL
);


ALTER TABLE public.many_unit_has_many_general_tag OWNER TO "SynologyPhotos";

--
-- Name: general_tag_album_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.general_tag_album_view AS
 SELECT t.id AS id_general_tag,
    t.name,
    t.normalized_name,
    ss.item_count,
    t.id_user
   FROM public.general_tag t,
    ( SELECT count(DISTINCT u.id_item) AS item_count,
            r.id_general_tag,
            u.id_user
           FROM public.many_unit_has_many_general_tag r,
            public.unit u
          WHERE ((u.id = r.id_unit) AND (u.is_major = true))
          GROUP BY r.id_general_tag, u.id_user) ss
  WHERE ((t.id = ss.id_general_tag) AND (t.id_user = ss.id_user));


ALTER TABLE public.general_tag_album_view OWNER TO "SynologyPhotos";

--
-- Name: general_tag_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.general_tag_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.general_tag_id_seq OWNER TO "SynologyPhotos";

--
-- Name: general_tag_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.general_tag_id_seq OWNED BY public.general_tag.id;


--
-- Name: general_tag_timeline_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.general_tag_timeline_view AS
SELECT
    NULL::integer AS id_item,
    NULL::integer AS id_user,
    NULL::smallint AS item_type,
    NULL::smallint AS unit_type,
    NULL::integer AS id_unit,
    NULL::integer[] AS id_general_tag,
    NULL::bigint AS takentime;


ALTER TABLE public.general_tag_timeline_view OWNER TO "SynologyPhotos";

--
-- Name: geocoding; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.geocoding (
    id integer NOT NULL,
    id_user integer NOT NULL,
    grouping_key text NOT NULL,
    level_1 integer,
    level_2 integer,
    level_3 integer,
    level_4 integer,
    level_5 integer,
    level_6 integer,
    admin_1 smallint,
    admin_2 smallint,
    admin_3 smallint,
    admin_4 smallint,
    admin_5 smallint,
    admin_6 smallint
);


ALTER TABLE public.geocoding OWNER TO "SynologyPhotos";

--
-- Name: geocoding_album_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.geocoding_album_view AS
 SELECT s.id_geocoding,
    geocoding.id_user,
    s.item_count,
    album_count_table.count AS album_count,
    geocoding.level_1
   FROM public.geocoding,
    ( SELECT u.id_geocoding,
            u.id_user,
            count(DISTINCT u.id_item) AS item_count
           FROM public.unit u
          WHERE (u.is_major = true)
          GROUP BY u.id_geocoding, u.id_user
         HAVING (u.id_geocoding IS NOT NULL)) s,
    ( SELECT geocoding_1.level_1,
            geocoding_1.id_user,
            count(*) AS count
           FROM public.geocoding geocoding_1
          GROUP BY geocoding_1.level_1, geocoding_1.id_user) album_count_table
  WHERE ((geocoding.id = s.id_geocoding) AND (geocoding.level_1 = album_count_table.level_1) AND (geocoding.id_user = s.id_user) AND (s.id_user = album_count_table.id_user));


ALTER TABLE public.geocoding_album_view OWNER TO "SynologyPhotos";

--
-- Name: geocoding_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.geocoding_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.geocoding_id_seq OWNER TO "SynologyPhotos";

--
-- Name: geocoding_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.geocoding_id_seq OWNED BY public.geocoding.id;


--
-- Name: geocoding_info; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.geocoding_info (
    id integer NOT NULL,
    id_user integer NOT NULL,
    lang smallint NOT NULL,
    first_level text NOT NULL,
    second_level text NOT NULL,
    country text NOT NULL,
    id_geocoding integer
);


ALTER TABLE public.geocoding_info OWNER TO "SynologyPhotos";

--
-- Name: geocoding_info_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.geocoding_info_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.geocoding_info_id_seq OWNER TO "SynologyPhotos";

--
-- Name: geocoding_info_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.geocoding_info_id_seq OWNED BY public.geocoding_info.id;


--
-- Name: geocoding_timeline_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.geocoding_timeline_view AS
 SELECT unit.id_item,
    unit.id_user,
    unit.item_type,
    unit.type AS unit_type,
    unit.takentime,
    unit.id AS id_unit,
    unit.id_geocoding
   FROM public.unit
  WHERE (unit.is_major = true);


ALTER TABLE public.geocoding_timeline_view OWNER TO "SynologyPhotos";

--
-- Name: group_info; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.group_info (
    id integer NOT NULL,
    gid bigint,
    name text NOT NULL,
    enable boolean DEFAULT false NOT NULL
);


ALTER TABLE public.group_info OWNER TO "SynologyPhotos";

--
-- Name: group_info_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.group_info_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.group_info_id_seq OWNER TO "SynologyPhotos";

--
-- Name: group_info_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.group_info_id_seq OWNED BY public.group_info.id;


--
-- Name: index_queue; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.index_queue (
    id integer NOT NULL,
    id_user integer NOT NULL,
    id_unit integer NOT NULL,
    type smallint DEFAULT 0 NOT NULL,
    status smallint DEFAULT 0 NOT NULL,
    task bytea NOT NULL
);


ALTER TABLE public.index_queue OWNER TO "SynologyPhotos";

--
-- Name: index_queue_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.index_queue_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.index_queue_id_seq OWNER TO "SynologyPhotos";

--
-- Name: index_queue_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.index_queue_id_seq OWNED BY public.index_queue.id;


--
-- Name: iso; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.iso (
    id integer NOT NULL,
    name text NOT NULL,
    normalized_name text NOT NULL
);


ALTER TABLE public.iso OWNER TO "SynologyPhotos";

--
-- Name: iso_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.iso_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.iso_id_seq OWNER TO "SynologyPhotos";

--
-- Name: iso_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.iso_id_seq OWNED BY public.iso.id;


--
-- Name: item; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.item (
    id integer NOT NULL,
    id_user integer NOT NULL,
    type smallint NOT NULL,
    id_similar_group integer,
    is_similar_top_pick boolean
);


ALTER TABLE public.item OWNER TO "SynologyPhotos";

--
-- Name: item_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.item_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.item_id_seq OWNER TO "SynologyPhotos";

--
-- Name: item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.item_id_seq OWNED BY public.item.id;


--
-- Name: lens; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.lens (
    id integer NOT NULL,
    name text NOT NULL,
    normalized_name text NOT NULL
);


ALTER TABLE public.lens OWNER TO "SynologyPhotos";

--
-- Name: lens_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.lens_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.lens_id_seq OWNER TO "SynologyPhotos";

--
-- Name: lens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.lens_id_seq OWNED BY public.lens.id;


--
-- Name: level_1_timeline_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.level_1_timeline_view AS
 SELECT unit.id_item,
    unit.id_user,
    unit.item_type,
    unit.type AS unit_type,
    unit.takentime,
    unit.id AS id_unit,
    geocoding.level_1 AS level,
    geocoding.admin_1 AS admin
   FROM (public.unit
     LEFT JOIN public.geocoding ON (((unit.id_geocoding = geocoding.id) AND (unit.id_user = geocoding.id_user))))
  WHERE ((unit.is_major = true) AND (unit.id_geocoding IS NOT NULL));


ALTER TABLE public.level_1_timeline_view OWNER TO "SynologyPhotos";

--
-- Name: level_2_timeline_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.level_2_timeline_view AS
 SELECT unit.id_item,
    unit.id_user,
    unit.item_type,
    unit.type AS unit_type,
    unit.takentime,
    unit.id AS id_unit,
    geocoding.level_2 AS level,
    geocoding.admin_2 AS admin
   FROM (public.unit
     LEFT JOIN public.geocoding ON (((unit.id_geocoding = geocoding.id) AND (unit.id_user = geocoding.id_user))))
  WHERE ((unit.is_major = true) AND (unit.id_geocoding IS NOT NULL));


ALTER TABLE public.level_2_timeline_view OWNER TO "SynologyPhotos";

--
-- Name: level_3_timeline_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.level_3_timeline_view AS
 SELECT unit.id_item,
    unit.id_user,
    unit.item_type,
    unit.type AS unit_type,
    unit.takentime,
    unit.id AS id_unit,
    geocoding.level_3 AS level,
    geocoding.admin_3 AS admin
   FROM (public.unit
     LEFT JOIN public.geocoding ON (((unit.id_geocoding = geocoding.id) AND (unit.id_user = geocoding.id_user))))
  WHERE ((unit.is_major = true) AND (unit.id_geocoding IS NOT NULL));


ALTER TABLE public.level_3_timeline_view OWNER TO "SynologyPhotos";

--
-- Name: level_4_timeline_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.level_4_timeline_view AS
 SELECT unit.id_item,
    unit.id_user,
    unit.item_type,
    unit.type AS unit_type,
    unit.takentime,
    unit.id AS id_unit,
    geocoding.level_4 AS level,
    geocoding.admin_4 AS admin
   FROM (public.unit
     LEFT JOIN public.geocoding ON (((unit.id_geocoding = geocoding.id) AND (unit.id_user = geocoding.id_user))))
  WHERE ((unit.is_major = true) AND (unit.id_geocoding IS NOT NULL));


ALTER TABLE public.level_4_timeline_view OWNER TO "SynologyPhotos";

--
-- Name: level_5_timeline_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.level_5_timeline_view AS
 SELECT unit.id_item,
    unit.id_user,
    unit.item_type,
    unit.type AS unit_type,
    unit.takentime,
    unit.id AS id_unit,
    geocoding.level_5 AS level,
    geocoding.admin_5 AS admin
   FROM (public.unit
     LEFT JOIN public.geocoding ON (((unit.id_geocoding = geocoding.id) AND (unit.id_user = geocoding.id_user))))
  WHERE ((unit.is_major = true) AND (unit.id_geocoding IS NOT NULL));


ALTER TABLE public.level_5_timeline_view OWNER TO "SynologyPhotos";

--
-- Name: level_6_timeline_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.level_6_timeline_view AS
 SELECT unit.id_item,
    unit.id_user,
    unit.item_type,
    unit.type AS unit_type,
    unit.takentime,
    unit.id AS id_unit,
    geocoding.level_6 AS level,
    geocoding.admin_6 AS admin
   FROM (public.unit
     LEFT JOIN public.geocoding ON (((unit.id_geocoding = geocoding.id) AND (unit.id_user = geocoding.id_user))))
  WHERE ((unit.is_major = true) AND (unit.id_geocoding IS NOT NULL));


ALTER TABLE public.level_6_timeline_view OWNER TO "SynologyPhotos";

--
-- Name: live_additional; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.live_additional (
    grouping_key text NOT NULL,
    id_unit integer
);


ALTER TABLE public.live_additional OWNER TO "SynologyPhotos";

--
-- Name: split_filename; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.split_filename (
    id_unit integer NOT NULL,
    name text NOT NULL,
    lower_extension text NOT NULL
);


ALTER TABLE public.split_filename OWNER TO "SynologyPhotos";

--
-- Name: live; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.live AS
 SELECT live_unit.id,
    live_unit.id_user,
    live_unit.item_type,
    live_unit.type,
    live_unit.filename,
    live_unit.filesize,
    live_unit.createtime,
    live_unit.takentime,
    live_unit.mtime,
    live_unit.duplicate_hash,
    live_unit.cache_key,
    live_unit.resolution,
    live_unit.index_stage,
    live_unit.version,
    live_unit.id_item,
    live_unit.id_folder,
    live_unit.id_geocoding,
    live_unit.is_major,
    live_additional.grouping_key,
    s.name AS name_no_ext
   FROM public.live_additional,
    ( SELECT unit.id,
            unit.id_user,
            unit.type,
            unit.item_type,
            unit.filename,
            unit.filesize,
            unit.createtime,
            unit.mtime,
            unit.takentime,
            unit.duplicate_hash,
            unit.cache_key,
            unit.resolution,
            unit.index_stage,
            unit.version,
            unit.id_geocoding,
            unit.id_item,
            unit.mobile_cache_mtime,
            unit.reindex_flag,
            unit.normalized_filename,
            unit.is_major,
            unit.id_folder
           FROM public.unit
          WHERE (unit.item_type = 3)) live_unit,
    public.split_filename s
  WHERE ((live_unit.id = live_additional.id_unit) AND (live_unit.id = s.id_unit));


ALTER TABLE public.live OWNER TO "SynologyPhotos";

--
-- Name: many_item_has_many_normal_album; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.many_item_has_many_normal_album (
    sequence double precision DEFAULT 0 NOT NULL,
    item_provider_id_user integer,
    id_item integer NOT NULL,
    id_normal_album integer NOT NULL,
    album_id_user integer NOT NULL
);


ALTER TABLE public.many_item_has_many_normal_album OWNER TO "SynologyPhotos";

--
-- Name: many_unit_has_many_administrative; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.many_unit_has_many_administrative (
    id_unit integer NOT NULL,
    id_administrative integer NOT NULL,
    id_user integer
);


ALTER TABLE public.many_unit_has_many_administrative OWNER TO "SynologyPhotos";

--
-- Name: many_unit_has_many_concept; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.many_unit_has_many_concept (
    id_unit integer NOT NULL,
    id_concept integer NOT NULL,
    id_user integer NOT NULL,
    confidence numeric(5,4) NOT NULL
);


ALTER TABLE public.many_unit_has_many_concept OWNER TO "SynologyPhotos";

--
-- Name: many_unit_has_many_favorite_user; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.many_unit_has_many_favorite_user (
    id_unit integer NOT NULL,
    id_user integer NOT NULL,
    id_favorite_user integer NOT NULL
);


ALTER TABLE public.many_unit_has_many_favorite_user OWNER TO "SynologyPhotos";

--
-- Name: many_unit_has_many_person; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.many_unit_has_many_person (
    id_unit integer NOT NULL,
    id_person integer NOT NULL,
    id_user integer
);


ALTER TABLE public.many_unit_has_many_person OWNER TO "SynologyPhotos";

--
-- Name: metadata; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.metadata (
    id_unit integer,
    description text NOT NULL,
    orientation smallint DEFAULT 1 NOT NULL,
    focal_length text NOT NULL,
    iso text NOT NULL,
    exposure_time text NOT NULL,
    aperture text NOT NULL,
    lens text NOT NULL,
    camera text NOT NULL,
    latitude double precision,
    longitude double precision,
    flash smallint,
    orientation_original smallint DEFAULT 1 NOT NULL,
    rating smallint DEFAULT 0 NOT NULL,
    normalized_description text DEFAULT ''::text NOT NULL
);


ALTER TABLE public.metadata OWNER TO "SynologyPhotos";

--
-- Name: mobile_config; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.mobile_config (
    uuid text NOT NULL,
    config text NOT NULL
);


ALTER TABLE public.mobile_config OWNER TO "SynologyPhotos";

--
-- Name: motion_photo_additional; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.motion_photo_additional (
    duration bigint NOT NULL,
    video_info json NOT NULL,
    audio_info json NOT NULL,
    id_unit integer
);


ALTER TABLE public.motion_photo_additional OWNER TO "SynologyPhotos";

--
-- Name: thumbnail; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.thumbnail (
    type smallint NOT NULL,
    status smallint NOT NULL,
    id_unit integer
);


ALTER TABLE public.thumbnail OWNER TO "SynologyPhotos";

--
-- Name: video_additional; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.video_additional (
    duration bigint NOT NULL,
    video_info json NOT NULL,
    audio_info json NOT NULL,
    id_unit integer
);


ALTER TABLE public.video_additional OWNER TO "SynologyPhotos";

--
-- Name: need_convert_thumbnail_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.need_convert_thumbnail_view AS
 SELECT u.id,
    u.id_user,
    u.filename,
    u.type AS unit_type,
    u.item_type,
        CASE
            WHEN (u.type = 1) THEN public.get_json_value(v.video_info, 'video_codec'::text)
            ELSE ''::text
        END AS codec,
    t.status,
    s.lower_extension,
    (array_agg(t.type))::integer[] AS thumbnail_type
   FROM (((public.unit u
     LEFT JOIN public.video_additional v ON ((u.id = v.id_unit)))
     JOIN public.split_filename s ON ((u.id = s.id_unit)))
     JOIN public.thumbnail t ON (((u.id = t.id_unit) AND ((t.type = 1) OR (t.type = 6)) AND (t.status = 3))))
  GROUP BY u.id, u.id_user, u.filename, u.type, u.item_type, t.status, s.lower_extension,
        CASE
            WHEN (u.type = 1) THEN public.get_json_value(v.video_info, 'video_codec'::text)
            ELSE ''::text
        END;


ALTER TABLE public.need_convert_thumbnail_view OWNER TO "SynologyPhotos";

--
-- Name: normal_album_photowall_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.normal_album_photowall_view AS
 SELECT m.id_normal_album,
    m.id_item,
    m.item_provider_id_user,
    u.id_unit,
    u.takentime,
    u.filesize,
    u.normalized_filename,
    m.sequence,
    m.album_id_user AS id_user,
    i.type AS item_type,
    u.name_for_sort
   FROM public.many_item_has_many_normal_album m,
    public.item i,
    ( SELECT unit.id_item,
            unit.id AS id_unit,
            unit.takentime,
            unit.filesize,
            unit.normalized_filename,
            unit.name_for_sort
           FROM public.unit
          WHERE (unit.is_major = true)) u
  WHERE ((u.id_item = m.id_item) AND (i.id = m.id_item));


ALTER TABLE public.normal_album_photowall_view OWNER TO "SynologyPhotos";

--
-- Name: notification; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.notification (
    id_user integer NOT NULL,
    event text NOT NULL,
    target_id integer NOT NULL
);


ALTER TABLE public.notification OWNER TO "SynologyPhotos";

--
-- Name: one_filter_has_many_unit; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.one_filter_has_many_unit (
    id_unit integer NOT NULL,
    id_aperture integer,
    id_camera integer,
    id_exposure_time integer,
    id_flash integer,
    id_focal_length integer,
    id_folder integer,
    id_iso integer,
    id_item_type integer,
    id_lens integer,
    id_takentime integer,
    id_user integer,
    id_rating smallint DEFAULT 0 NOT NULL,
    is_major boolean DEFAULT true NOT NULL
);


ALTER TABLE public.one_filter_has_many_unit OWNER TO "SynologyPhotos";

--
-- Name: person; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.person (
    id integer NOT NULL,
    id_user integer NOT NULL,
    name text NOT NULL,
    hidden boolean DEFAULT false NOT NULL,
    custom_cover boolean DEFAULT false NOT NULL,
    cover integer,
    normalized_name text DEFAULT ''::text NOT NULL,
    created_time bigint DEFAULT 0 NOT NULL
);


ALTER TABLE public.person OWNER TO "SynologyPhotos";

--
-- Name: person_item_count; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.person_item_count (
    id_person integer NOT NULL,
    id_user integer NOT NULL,
    item_count bigint
);


ALTER TABLE public.person_item_count OWNER TO "SynologyPhotos";

--
-- Name: person_album_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.person_album_view AS
 SELECT person_item_count.id_person,
    person.id_user,
    person.name,
    person.hidden,
    person.cover,
    person_item_count.item_count,
    person.normalized_name
   FROM public.person,
    public.person_item_count
  WHERE ((person_item_count.id_person = person.id) AND (person_item_count.id_user = person.id_user));


ALTER TABLE public.person_album_view OWNER TO "SynologyPhotos";

--
-- Name: person_face_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.person_face_view AS
 SELECT face.id,
    face.id_user,
    face.id_person,
    face.id_unit,
    face.score,
    unit.is_major,
    unit.id_item
   FROM public.face,
    public.unit
  WHERE ((unit.id = face.id_unit) AND (unit.id_user = face.id_user));


ALTER TABLE public.person_face_view OWNER TO "SynologyPhotos";

--
-- Name: person_group; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.person_group (
    id integer NOT NULL,
    weight integer,
    feature bytea,
    id_user integer NOT NULL,
    id_cluster integer,
    is_manual boolean DEFAULT false NOT NULL
);


ALTER TABLE public.person_group OWNER TO "SynologyPhotos";

--
-- Name: person_group_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.person_group_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.person_group_id_seq OWNER TO "SynologyPhotos";

--
-- Name: person_group_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.person_group_id_seq OWNED BY public.person_group.id;


--
-- Name: person_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.person_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.person_id_seq OWNER TO "SynologyPhotos";

--
-- Name: person_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.person_id_seq OWNED BY public.person.id;


--
-- Name: person_migration_mapping; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.person_migration_mapping (
    id_user integer NOT NULL,
    id_person_source integer NOT NULL,
    id_person integer NOT NULL,
    named_by_migration boolean NOT NULL
);


ALTER TABLE public.person_migration_mapping OWNER TO "SynologyPhotos";

--
-- Name: person_timeline_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.person_timeline_view AS
SELECT
    NULL::integer AS id_item,
    NULL::integer AS id_user,
    NULL::smallint AS item_type,
    NULL::smallint AS unit_type,
    NULL::integer AS id_unit,
    NULL::integer[] AS id_person,
    NULL::bigint AS takentime;


ALTER TABLE public.person_timeline_view OWNER TO "SynologyPhotos";

--
-- Name: photo_request; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.photo_request (
    passphrase_share text NOT NULL,
    id_user integer NOT NULL,
    modified_time bigint NOT NULL,
    filesize_limit bigint DEFAULT 0 NOT NULL,
    subject text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    id_album integer,
    album_passphrase_share text,
    folder_id_user integer NOT NULL,
    folder_home_path text NOT NULL
);


ALTER TABLE public.photo_request OWNER TO "SynologyPhotos";

--
-- Name: recently_added_timeline_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.recently_added_timeline_view AS
 SELECT unit.id_item,
    unit.id_user,
    unit.item_type,
    unit.type AS unit_type,
    (unit.createtime / 1000) AS createtime,
    unit.id AS id_unit
   FROM public.unit
  WHERE ((unit.is_major = true) AND ((unit.createtime)::double precision > ((date_part('epoch'::text, now()) - (2592000)::double precision) * (1000)::double precision)));


ALTER TABLE public.recently_added_timeline_view OWNER TO "SynologyPhotos";

--
-- Name: regenerating_thumbnail_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.regenerating_thumbnail_view AS
 SELECT u.id,
    u.id_user,
    u.filename,
    u.type AS unit_type,
    t.status,
    t.type AS thumbnail_type
   FROM (public.unit u
     JOIN public.thumbnail t ON (((u.id = t.id_unit) AND (t.type = 0) AND (t.status >= 100))));


ALTER TABLE public.regenerating_thumbnail_view OWNER TO "SynologyPhotos";

--
-- Name: search_timeline; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.search_timeline (
    id_item integer NOT NULL,
    id_user integer NOT NULL,
    item_type smallint DEFAULT 0 NOT NULL,
    unit_type smallint NOT NULL,
    takentime bigint DEFAULT 0 NOT NULL,
    id_unit integer NOT NULL
);


ALTER TABLE public.search_timeline OWNER TO "SynologyPhotos";

--
-- Name: share_album_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.share_album_view AS
 SELECT album.id,
    album.id_user,
    album.name,
    album.type,
    album.shared,
    album.create_time,
    album.cover,
    album.sort_by,
    album.sort_direction,
    album.passphrase_share,
    album.version,
    album.item_count,
    share.modified_time,
    album.normalized_name,
    album.start_time,
    album.end_time,
    album.name_for_sort
   FROM public.album,
    public.share
  WHERE (album.passphrase_share = share.passphrase);


ALTER TABLE public.share_album_view OWNER TO "SynologyPhotos";

--
-- Name: share_permission; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.share_permission (
    id integer NOT NULL,
    id_user integer NOT NULL,
    permission smallint NOT NULL,
    target_type smallint NOT NULL,
    target_id integer NOT NULL,
    passphrase_share text NOT NULL
);


ALTER TABLE public.share_permission OWNER TO "SynologyPhotos";

--
-- Name: share_permission_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.share_permission_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.share_permission_id_seq OWNER TO "SynologyPhotos";

--
-- Name: share_permission_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.share_permission_id_seq OWNED BY public.share_permission.id;


--
-- Name: user_info; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_info (
    id integer NOT NULL,
    uid bigint,
    name text NOT NULL,
    config json DEFAULT '{}'::json NOT NULL,
    enable boolean DEFAULT false NOT NULL
);


ALTER TABLE public.user_info OWNER TO "SynologyPhotos";

--
-- Name: share_with_member_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.share_with_member_view AS
 SELECT share_permission.id,
    share_permission.permission,
    share_permission.target_type,
    share_permission.target_id,
    share.id_user,
    share.passphrase,
    share.type,
    share.expired_time,
    share.modified_time
   FROM public.share_permission,
    public.share
  WHERE ((share_permission.passphrase_share = share.passphrase) AND (share.enable = true) AND (share.id_user IN ( SELECT user_info.id
           FROM public.user_info
          WHERE (user_info.enable = true))));


ALTER TABLE public.share_with_member_view OWNER TO "SynologyPhotos";

--
-- Name: similar_group; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.similar_group (
    id integer NOT NULL,
    id_user integer NOT NULL,
    top_pick integer,
    item_count integer NOT NULL,
    update_at bigint NOT NULL,
    custom_top_pick boolean DEFAULT false NOT NULL,
    version bigint NOT NULL
);


ALTER TABLE public.similar_group OWNER TO "SynologyPhotos";

--
-- Name: similar_group_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.similar_group_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.similar_group_id_seq OWNER TO "SynologyPhotos";

--
-- Name: similar_group_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.similar_group_id_seq OWNED BY public.similar_group.id;


--
-- Name: similar_hash; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.similar_hash (
    id_unit integer NOT NULL,
    id_user integer NOT NULL,
    pdq_hash bigint[],
    takentime bigint,
    need_action boolean DEFAULT true NOT NULL,
    skip boolean DEFAULT false NOT NULL,
    is_major boolean NOT NULL,
    id_item integer NOT NULL,
    type smallint DEFAULT 0 NOT NULL
);


ALTER TABLE public.similar_hash OWNER TO "SynologyPhotos";

--
-- Name: similar_timeline; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.similar_timeline (
    id_unit integer NOT NULL,
    id_item integer NOT NULL,
    id_user integer NOT NULL,
    takentime bigint,
    id_similar_group integer,
    similar_group_item_count integer
);


ALTER TABLE public.similar_timeline OWNER TO "SynologyPhotos";

--
-- Name: takentime; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.takentime (
    id integer NOT NULL,
    takentime_day text NOT NULL,
    takentime_month text NOT NULL,
    takentime bigint DEFAULT 0 NOT NULL
);


ALTER TABLE public.takentime OWNER TO "SynologyPhotos";

--
-- Name: takentime_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.takentime_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.takentime_id_seq OWNER TO "SynologyPhotos";

--
-- Name: takentime_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.takentime_id_seq OWNED BY public.takentime.id;


--
-- Name: team_library_folder_has_many_sorting; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.team_library_folder_has_many_sorting (
    id_user integer NOT NULL,
    id_folder integer NOT NULL,
    sort_by smallint DEFAULT 0 NOT NULL,
    sort_direction smallint DEFAULT 0 NOT NULL
);


ALTER TABLE public.team_library_folder_has_many_sorting OWNER TO "SynologyPhotos";

--
-- Name: team_library_group_permission; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.team_library_group_permission (
    id_group integer NOT NULL,
    permission smallint DEFAULT 0 NOT NULL,
    auto_backup boolean DEFAULT false NOT NULL
);


ALTER TABLE public.team_library_group_permission OWNER TO "SynologyPhotos";

--
-- Name: team_library_user_permission; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.team_library_user_permission (
    id_user integer NOT NULL,
    permission smallint DEFAULT 0 NOT NULL,
    auto_backup boolean DEFAULT false NOT NULL
);


ALTER TABLE public.team_library_user_permission OWNER TO "SynologyPhotos";

--
-- Name: thumb_preview; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.thumb_preview (
    picture oid NOT NULL,
    id_unit integer NOT NULL
);


ALTER TABLE public.thumb_preview OWNER TO "SynologyPhotos";

--
-- Name: thumbnail_version; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.thumbnail_version (
    id_user integer NOT NULL,
    id_unit integer NOT NULL,
    version bigint NOT NULL,
    sm_size_hash text DEFAULT ''::text NOT NULL
);


ALTER TABLE public.thumbnail_version OWNER TO "SynologyPhotos";

--
-- Name: timeline_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.timeline_view AS
 SELECT unit.id_item,
    unit.id_user,
    unit.item_type,
    unit.type AS unit_type,
    unit.takentime,
    unit.id AS id_unit
   FROM public.unit
  WHERE (unit.is_major = true);


ALTER TABLE public.timeline_view OWNER TO "SynologyPhotos";

--
-- Name: tmp_old_named; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tmp_old_named (
    old_person integer,
    name text,
    old_unit integer
);


ALTER TABLE public.tmp_old_named OWNER TO postgres;

--
-- Name: tmp_old_unit2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tmp_old_unit2 (
    old_id integer,
    old_user integer,
    folder text,
    filename text
);


ALTER TABLE public.tmp_old_unit2 OWNER TO postgres;

--
-- Name: tmp_unit_map; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tmp_unit_map (
    old_id integer,
    old_user integer,
    new_id integer,
    new_user integer
);


ALTER TABLE public.tmp_unit_map OWNER TO postgres;

--
-- Name: udc_event; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.udc_event (
    id_user integer NOT NULL,
    "timestamp" bigint NOT NULL,
    type text NOT NULL,
    payload text
);


ALTER TABLE public.udc_event OWNER TO "SynologyPhotos";

--
-- Name: udc_statistic; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.udc_statistic (
    id_user integer NOT NULL,
    key text NOT NULL,
    value text NOT NULL
);


ALTER TABLE public.udc_statistic OWNER TO "SynologyPhotos";

--
-- Name: unit_file_extension_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.unit_file_extension_view AS
 SELECT unit.id AS id_unit,
    unit.id_user,
    unit.item_type,
    unit.type AS unit_type,
    reverse(split_part(reverse(unit.normalized_filename), '.'::text, 1)) AS extension
   FROM public.unit;


ALTER TABLE public.unit_file_extension_view OWNER TO "SynologyPhotos";

--
-- Name: unit_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.unit_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.unit_id_seq OWNER TO "SynologyPhotos";

--
-- Name: unit_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.unit_id_seq OWNED BY public.unit.id;


--
-- Name: unit_to_general_tag_view; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.unit_to_general_tag_view AS
 SELECT g.id AS id_general_tag,
    g.name,
    g.name_for_sort,
    r.id_unit,
    g.id_user
   FROM (public.general_tag g
     JOIN public.many_unit_has_many_general_tag r ON ((g.id = r.id_general_tag)));


ALTER TABLE public.unit_to_general_tag_view OWNER TO "SynologyPhotos";

--
-- Name: user_event_history_0; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_event_history_0 (
    version bigint NOT NULL,
    id_user integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer[] NOT NULL,
    target_id_user integer NOT NULL,
    trigger_id_user integer,
    event_type text NOT NULL,
    event_detail json
);


ALTER TABLE public.user_event_history_0 OWNER TO "SynologyPhotos";

--
-- Name: user_event_history_1; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_event_history_1 (
    version bigint NOT NULL,
    id_user integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer[] NOT NULL,
    target_id_user integer NOT NULL,
    trigger_id_user integer,
    event_type text NOT NULL,
    event_detail json
);


ALTER TABLE public.user_event_history_1 OWNER TO "SynologyPhotos";

--
-- Name: user_event_history_10; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_event_history_10 (
    version bigint NOT NULL,
    id_user integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer[] NOT NULL,
    target_id_user integer NOT NULL,
    trigger_id_user integer,
    event_type text NOT NULL,
    event_detail json
);


ALTER TABLE public.user_event_history_10 OWNER TO "SynologyPhotos";

--
-- Name: user_event_history_11; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_event_history_11 (
    version bigint NOT NULL,
    id_user integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer[] NOT NULL,
    target_id_user integer NOT NULL,
    trigger_id_user integer,
    event_type text NOT NULL,
    event_detail json
);


ALTER TABLE public.user_event_history_11 OWNER TO "SynologyPhotos";

--
-- Name: user_event_history_12; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_event_history_12 (
    version bigint NOT NULL,
    id_user integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer[] NOT NULL,
    target_id_user integer NOT NULL,
    trigger_id_user integer,
    event_type text NOT NULL,
    event_detail json
);


ALTER TABLE public.user_event_history_12 OWNER TO "SynologyPhotos";

--
-- Name: user_event_history_13; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_event_history_13 (
    version bigint NOT NULL,
    id_user integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer[] NOT NULL,
    target_id_user integer NOT NULL,
    trigger_id_user integer,
    event_type text NOT NULL,
    event_detail json
);


ALTER TABLE public.user_event_history_13 OWNER TO "SynologyPhotos";

--
-- Name: user_event_history_2; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_event_history_2 (
    version bigint NOT NULL,
    id_user integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer[] NOT NULL,
    target_id_user integer NOT NULL,
    trigger_id_user integer,
    event_type text NOT NULL,
    event_detail json
);


ALTER TABLE public.user_event_history_2 OWNER TO "SynologyPhotos";

--
-- Name: user_event_history_3; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_event_history_3 (
    version bigint NOT NULL,
    id_user integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer[] NOT NULL,
    target_id_user integer NOT NULL,
    trigger_id_user integer,
    event_type text NOT NULL,
    event_detail json
);


ALTER TABLE public.user_event_history_3 OWNER TO "SynologyPhotos";

--
-- Name: user_event_history_4; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_event_history_4 (
    version bigint NOT NULL,
    id_user integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer[] NOT NULL,
    target_id_user integer NOT NULL,
    trigger_id_user integer,
    event_type text NOT NULL,
    event_detail json
);


ALTER TABLE public.user_event_history_4 OWNER TO "SynologyPhotos";

--
-- Name: user_event_history_5; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_event_history_5 (
    version bigint NOT NULL,
    id_user integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer[] NOT NULL,
    target_id_user integer NOT NULL,
    trigger_id_user integer,
    event_type text NOT NULL,
    event_detail json
);


ALTER TABLE public.user_event_history_5 OWNER TO "SynologyPhotos";

--
-- Name: user_event_history_6; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_event_history_6 (
    version bigint NOT NULL,
    id_user integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer[] NOT NULL,
    target_id_user integer NOT NULL,
    trigger_id_user integer,
    event_type text NOT NULL,
    event_detail json
);


ALTER TABLE public.user_event_history_6 OWNER TO "SynologyPhotos";

--
-- Name: user_event_history_7; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_event_history_7 (
    version bigint NOT NULL,
    id_user integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer[] NOT NULL,
    target_id_user integer NOT NULL,
    trigger_id_user integer,
    event_type text NOT NULL,
    event_detail json
);


ALTER TABLE public.user_event_history_7 OWNER TO "SynologyPhotos";

--
-- Name: user_event_history_8; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_event_history_8 (
    version bigint NOT NULL,
    id_user integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer[] NOT NULL,
    target_id_user integer NOT NULL,
    trigger_id_user integer,
    event_type text NOT NULL,
    event_detail json
);


ALTER TABLE public.user_event_history_8 OWNER TO "SynologyPhotos";

--
-- Name: user_event_history_9; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_event_history_9 (
    version bigint NOT NULL,
    id_user integer NOT NULL,
    target_type smallint NOT NULL,
    target_id integer[] NOT NULL,
    target_id_user integer NOT NULL,
    trigger_id_user integer,
    event_type text NOT NULL,
    event_detail json
);


ALTER TABLE public.user_event_history_9 OWNER TO "SynologyPhotos";

--
-- Name: user_flag; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.user_flag (
    id_user integer NOT NULL,
    flag text NOT NULL,
    value text
);


ALTER TABLE public.user_flag OWNER TO "SynologyPhotos";

--
-- Name: user_info_id_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.user_info_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_info_id_seq OWNER TO "SynologyPhotos";

--
-- Name: user_info_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.user_info_id_seq OWNED BY public.user_info.id;


--
-- Name: version_time; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.version_time (
    version bigint NOT NULL,
    modified_time bigint NOT NULL
);


ALTER TABLE public.version_time OWNER TO "SynologyPhotos";

--
-- Name: version_time_0_version_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.version_time_0_version_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.version_time_0_version_seq OWNER TO "SynologyPhotos";

--
-- Name: version_time_0; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.version_time_0 (
    version bigint DEFAULT nextval('public.version_time_0_version_seq'::regclass) NOT NULL,
    modified_time bigint NOT NULL
);


ALTER TABLE public.version_time_0 OWNER TO "SynologyPhotos";

--
-- Name: version_time_1_version_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.version_time_1_version_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.version_time_1_version_seq OWNER TO "SynologyPhotos";

--
-- Name: version_time_1; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.version_time_1 (
    version bigint DEFAULT nextval('public.version_time_1_version_seq'::regclass) NOT NULL,
    modified_time bigint NOT NULL
);


ALTER TABLE public.version_time_1 OWNER TO "SynologyPhotos";

--
-- Name: version_time_2_version_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.version_time_2_version_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.version_time_2_version_seq OWNER TO "SynologyPhotos";

--
-- Name: version_time_2; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.version_time_2 (
    version bigint DEFAULT nextval('public.version_time_2_version_seq'::regclass) NOT NULL,
    modified_time bigint NOT NULL
);


ALTER TABLE public.version_time_2 OWNER TO "SynologyPhotos";

--
-- Name: version_time_3_version_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.version_time_3_version_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.version_time_3_version_seq OWNER TO "SynologyPhotos";

--
-- Name: version_time_3; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.version_time_3 (
    version bigint DEFAULT nextval('public.version_time_3_version_seq'::regclass) NOT NULL,
    modified_time bigint NOT NULL
);


ALTER TABLE public.version_time_3 OWNER TO "SynologyPhotos";

--
-- Name: version_time_version_seq; Type: SEQUENCE; Schema: public; Owner: SynologyPhotos
--

CREATE SEQUENCE public.version_time_version_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.version_time_version_seq OWNER TO "SynologyPhotos";

--
-- Name: version_time_version_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: SynologyPhotos
--

ALTER SEQUENCE public.version_time_version_seq OWNED BY public.version_time.version;


--
-- Name: video; Type: VIEW; Schema: public; Owner: SynologyPhotos
--

CREATE VIEW public.video AS
 SELECT video_unit.id,
    video_unit.id_user,
    video_unit.item_type,
    video_unit.type,
    video_unit.filename,
    video_unit.filesize,
    video_unit.createtime,
    video_unit.takentime,
    video_unit.mtime,
    video_unit.duplicate_hash,
    video_unit.cache_key,
    video_unit.resolution,
    video_unit.index_stage,
    video_unit.version,
    video_unit.id_item,
    video_unit.id_folder,
    video_unit.id_geocoding,
    video_unit.is_major,
    video_additional.duration,
    video_additional.video_info,
    video_additional.audio_info
   FROM public.video_additional,
    ( SELECT unit.id,
            unit.id_user,
            unit.type,
            unit.item_type,
            unit.filename,
            unit.filesize,
            unit.createtime,
            unit.mtime,
            unit.takentime,
            unit.duplicate_hash,
            unit.cache_key,
            unit.resolution,
            unit.index_stage,
            unit.version,
            unit.id_geocoding,
            unit.id_item,
            unit.mobile_cache_mtime,
            unit.reindex_flag,
            unit.normalized_filename,
            unit.is_major,
            unit.id_folder
           FROM public.unit
          WHERE (unit.type = 1)) video_unit
  WHERE (video_unit.id = video_additional.id_unit);


ALTER TABLE public.video OWNER TO "SynologyPhotos";

--
-- Name: video_convert; Type: TABLE; Schema: public; Owner: SynologyPhotos
--

CREATE TABLE public.video_convert (
    duration bigint NOT NULL,
    quality text DEFAULT ''::text NOT NULL,
    video_info json DEFAULT '{}'::json NOT NULL,
    audio_info json DEFAULT '{}'::json NOT NULL,
    id_unit integer
);


ALTER TABLE public.video_convert OWNER TO "SynologyPhotos";

--
-- Name: tables; Type: TABLE; Schema: test; Owner: SynologyPhotos
--

CREATE TABLE test.tables (
    table_schema text NOT NULL,
    table_name text NOT NULL,
    table_type text NOT NULL
);


ALTER TABLE test.tables OWNER TO "SynologyPhotos";

--
-- Name: activity id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.activity ALTER COLUMN id SET DEFAULT nextval('public.activity_id_seq'::regclass);


--
-- Name: address id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.address ALTER COLUMN id SET DEFAULT nextval('public.address_id_seq'::regclass);


--
-- Name: administrative id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.administrative ALTER COLUMN id SET DEFAULT nextval('public.administrative_id_seq'::regclass);


--
-- Name: album id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.album ALTER COLUMN id SET DEFAULT nextval('public.album_id_seq'::regclass);


--
-- Name: aperture id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.aperture ALTER COLUMN id SET DEFAULT nextval('public.aperture_id_seq'::regclass);


--
-- Name: async_db_migration_task id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.async_db_migration_task ALTER COLUMN id SET DEFAULT nextval('public.async_db_migration_task_id_seq'::regclass);


--
-- Name: background_task id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.background_task ALTER COLUMN id SET DEFAULT nextval('public.background_task_id_seq'::regclass);


--
-- Name: camera id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.camera ALTER COLUMN id SET DEFAULT nextval('public.camera_id_seq'::regclass);


--
-- Name: check_album_task id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.check_album_task ALTER COLUMN id SET DEFAULT nextval('public.check_album_task_id_seq'::regclass);


--
-- Name: cluster id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.cluster ALTER COLUMN id SET DEFAULT nextval('public.cluster_id_seq'::regclass);


--
-- Name: concept id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.concept ALTER COLUMN id SET DEFAULT nextval('public.concept_id_seq'::regclass);


--
-- Name: condition_album id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.condition_album ALTER COLUMN id SET DEFAULT nextval('public.album_id_seq'::regclass);


--
-- Name: condition_album shared; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.condition_album ALTER COLUMN shared SET DEFAULT false;


--
-- Name: condition_album cover; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.condition_album ALTER COLUMN cover SET DEFAULT 0;


--
-- Name: condition_album sort_by; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.condition_album ALTER COLUMN sort_by SET DEFAULT 0;


--
-- Name: condition_album sort_direction; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.condition_album ALTER COLUMN sort_direction SET DEFAULT 0;


--
-- Name: condition_album normalized_name; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.condition_album ALTER COLUMN normalized_name SET DEFAULT ''::text;


--
-- Name: condition_album name_for_sort; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.condition_album ALTER COLUMN name_for_sort SET DEFAULT ''::text;


--
-- Name: exposure_time id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.exposure_time ALTER COLUMN id SET DEFAULT nextval('public.exposure_time_id_seq'::regclass);


--
-- Name: face id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.face ALTER COLUMN id SET DEFAULT nextval('public.face_id_seq'::regclass);


--
-- Name: focal_length id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.focal_length ALTER COLUMN id SET DEFAULT nextval('public.focal_length_id_seq'::regclass);


--
-- Name: folder id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.folder ALTER COLUMN id SET DEFAULT nextval('public.folder_id_seq'::regclass);


--
-- Name: general_tag id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.general_tag ALTER COLUMN id SET DEFAULT nextval('public.general_tag_id_seq'::regclass);


--
-- Name: geocoding id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.geocoding ALTER COLUMN id SET DEFAULT nextval('public.geocoding_id_seq'::regclass);


--
-- Name: geocoding_info id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.geocoding_info ALTER COLUMN id SET DEFAULT nextval('public.geocoding_info_id_seq'::regclass);


--
-- Name: group_info id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.group_info ALTER COLUMN id SET DEFAULT nextval('public.group_info_id_seq'::regclass);


--
-- Name: index_queue id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.index_queue ALTER COLUMN id SET DEFAULT nextval('public.index_queue_id_seq'::regclass);


--
-- Name: iso id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.iso ALTER COLUMN id SET DEFAULT nextval('public.iso_id_seq'::regclass);


--
-- Name: item id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.item ALTER COLUMN id SET DEFAULT nextval('public.item_id_seq'::regclass);


--
-- Name: lens id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.lens ALTER COLUMN id SET DEFAULT nextval('public.lens_id_seq'::regclass);


--
-- Name: normal_album id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.normal_album ALTER COLUMN id SET DEFAULT nextval('public.album_id_seq'::regclass);


--
-- Name: normal_album shared; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.normal_album ALTER COLUMN shared SET DEFAULT false;


--
-- Name: normal_album cover; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.normal_album ALTER COLUMN cover SET DEFAULT 0;


--
-- Name: normal_album sort_by; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.normal_album ALTER COLUMN sort_by SET DEFAULT 0;


--
-- Name: normal_album sort_direction; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.normal_album ALTER COLUMN sort_direction SET DEFAULT 0;


--
-- Name: normal_album normalized_name; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.normal_album ALTER COLUMN normalized_name SET DEFAULT ''::text;


--
-- Name: normal_album name_for_sort; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.normal_album ALTER COLUMN name_for_sort SET DEFAULT ''::text;


--
-- Name: person id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.person ALTER COLUMN id SET DEFAULT nextval('public.person_id_seq'::regclass);


--
-- Name: person_group id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.person_group ALTER COLUMN id SET DEFAULT nextval('public.person_group_id_seq'::regclass);


--
-- Name: share_permission id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.share_permission ALTER COLUMN id SET DEFAULT nextval('public.share_permission_id_seq'::regclass);


--
-- Name: similar_group id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.similar_group ALTER COLUMN id SET DEFAULT nextval('public.similar_group_id_seq'::regclass);


--
-- Name: takentime id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.takentime ALTER COLUMN id SET DEFAULT nextval('public.takentime_id_seq'::regclass);


--
-- Name: unit id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.unit ALTER COLUMN id SET DEFAULT nextval('public.unit_id_seq'::regclass);


--
-- Name: user_info id; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_info ALTER COLUMN id SET DEFAULT nextval('public.user_info_id_seq'::regclass);


--
-- Name: version_time version; Type: DEFAULT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.version_time ALTER COLUMN version SET DEFAULT nextval('public.version_time_version_seq'::regclass);


--
-- Name: activity activity_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.activity
    ADD CONSTRAINT activity_id_primary PRIMARY KEY (id);


--
-- Name: address address_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.address
    ADD CONSTRAINT address_id_primary PRIMARY KEY (id);


--
-- Name: administrative adminstrative_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.administrative
    ADD CONSTRAINT adminstrative_pk PRIMARY KEY (id);


--
-- Name: album album_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.album
    ADD CONSTRAINT album_id_primary PRIMARY KEY (id);


--
-- Name: album album_uq; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.album
    ADD CONSTRAINT album_uq UNIQUE (passphrase_share);


--
-- Name: aperture aperture_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.aperture
    ADD CONSTRAINT aperture_pk PRIMARY KEY (id);


--
-- Name: aperture aperture_uq; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.aperture
    ADD CONSTRAINT aperture_uq UNIQUE (name);


--
-- Name: async_db_migration_task async_db_migration_task_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.async_db_migration_task
    ADD CONSTRAINT async_db_migration_task_pkey PRIMARY KEY (id);


--
-- Name: burst_additional burst_additional_uq; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.burst_additional
    ADD CONSTRAINT burst_additional_uq UNIQUE (id_unit);


--
-- Name: camera camera_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.camera
    ADD CONSTRAINT camera_pk PRIMARY KEY (id);


--
-- Name: camera camera_uq; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.camera
    ADD CONSTRAINT camera_uq UNIQUE (name);


--
-- Name: check_album_task check_album_task_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.check_album_task
    ADD CONSTRAINT check_album_task_pk PRIMARY KEY (id);


--
-- Name: cluster cluster_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.cluster
    ADD CONSTRAINT cluster_id_primary PRIMARY KEY (id);


--
-- Name: concept_album_additional concept_album_additional_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.concept_album_additional
    ADD CONSTRAINT concept_album_additional_pkey PRIMARY KEY (id_user, id_concept);


--
-- Name: concept concept_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.concept
    ADD CONSTRAINT concept_pkey PRIMARY KEY (id);


--
-- Name: concept_rawdata concept_rawdata_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.concept_rawdata
    ADD CONSTRAINT concept_rawdata_pkey PRIMARY KEY (id_unit);


--
-- Name: concept_threshold concept_threshold_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.concept_threshold
    ADD CONSTRAINT concept_threshold_pkey PRIMARY KEY (id_concept, version);


--
-- Name: condition_album condition_album_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.condition_album
    ADD CONSTRAINT condition_album_pk PRIMARY KEY (id);


--
-- Name: config config_key_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.config
    ADD CONSTRAINT config_key_primary PRIMARY KEY (key);


--
-- Name: convert_thumbnail_allocation convert_thumbnail_allocation_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.convert_thumbnail_allocation
    ADD CONSTRAINT convert_thumbnail_allocation_pkey PRIMARY KEY (session_id, id);


--
-- Name: dsm_group dsm_group_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.dsm_group
    ADD CONSTRAINT dsm_group_pkey PRIMARY KEY (gid);


--
-- Name: dsm_user dsm_user_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.dsm_user
    ADD CONSTRAINT dsm_user_pkey PRIMARY KEY (uid);


--
-- Name: exposure_time exposure_time_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.exposure_time
    ADD CONSTRAINT exposure_time_pk PRIMARY KEY (id);


--
-- Name: exposure_time exposure_time_uq; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.exposure_time
    ADD CONSTRAINT exposure_time_uq UNIQUE (name);


--
-- Name: face face_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.face
    ADD CONSTRAINT face_id_primary PRIMARY KEY (id);


--
-- Name: many_unit_has_many_favorite_user favorite_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_unit_has_many_favorite_user
    ADD CONSTRAINT favorite_pk PRIMARY KEY (id_unit, id_favorite_user);


--
-- Name: favorite_timeline favorite_timeline_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.favorite_timeline
    ADD CONSTRAINT favorite_timeline_pk PRIMARY KEY (id_unit);


--
-- Name: file_operation_error file_operation_error_uk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.file_operation_error
    ADD CONSTRAINT file_operation_error_uk UNIQUE (id_task, target_type, target_id);


--
-- Name: filter filter_uq; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.filter
    ADD CONSTRAINT filter_uq UNIQUE (id_unit, id_filter, filter_type, id_user);


--
-- Name: focal_length focal_length_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.focal_length
    ADD CONSTRAINT focal_length_pk PRIMARY KEY (id);


--
-- Name: focal_length focal_length_uq; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.focal_length
    ADD CONSTRAINT focal_length_uq UNIQUE (name);


--
-- Name: folder folder_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.folder
    ADD CONSTRAINT folder_id_primary PRIMARY KEY (id);


--
-- Name: folder folder_uq; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.folder
    ADD CONSTRAINT folder_uq UNIQUE (passphrase_share);


--
-- Name: general_tag general_tag_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.general_tag
    ADD CONSTRAINT general_tag_id_primary PRIMARY KEY (id);


--
-- Name: geocoding geocoding_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.geocoding
    ADD CONSTRAINT geocoding_id_primary PRIMARY KEY (id);


--
-- Name: geocoding_info geocoding_info_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.geocoding_info
    ADD CONSTRAINT geocoding_info_id_primary PRIMARY KEY (id);


--
-- Name: group_info gid_uk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.group_info
    ADD CONSTRAINT gid_uk UNIQUE (gid);


--
-- Name: group_info group_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.group_info
    ADD CONSTRAINT group_id_primary PRIMARY KEY (id);


--
-- Name: background_task id; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.background_task
    ADD CONSTRAINT id PRIMARY KEY (id);


--
-- Name: index_queue index_id_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.index_queue
    ADD CONSTRAINT index_id_pk PRIMARY KEY (id);


--
-- Name: iso iso_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.iso
    ADD CONSTRAINT iso_pk PRIMARY KEY (id);


--
-- Name: iso iso_uq; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.iso
    ADD CONSTRAINT iso_uq UNIQUE (name);


--
-- Name: item item_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.item
    ADD CONSTRAINT item_id_primary PRIMARY KEY (id);


--
-- Name: lens lens_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.lens
    ADD CONSTRAINT lens_pk PRIMARY KEY (id);


--
-- Name: lens lens_qu; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.lens
    ADD CONSTRAINT lens_qu UNIQUE (name);


--
-- Name: live_additional live_additional_uq; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.live_additional
    ADD CONSTRAINT live_additional_uq UNIQUE (id_unit);


--
-- Name: many_item_has_many_normal_album many_item_has_many_normal_album_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_item_has_many_normal_album
    ADD CONSTRAINT many_item_has_many_normal_album_pk PRIMARY KEY (id_item, id_normal_album);


--
-- Name: many_unit_has_many_administrative many_unit_has_many_administrative_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_unit_has_many_administrative
    ADD CONSTRAINT many_unit_has_many_administrative_pk PRIMARY KEY (id_unit, id_administrative);


--
-- Name: many_unit_has_many_concept many_unit_has_many_concept_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_unit_has_many_concept
    ADD CONSTRAINT many_unit_has_many_concept_pkey PRIMARY KEY (id_unit, id_concept);


--
-- Name: many_unit_has_many_general_tag many_unit_has_many_general_tag_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_unit_has_many_general_tag
    ADD CONSTRAINT many_unit_has_many_general_tag_pk PRIMARY KEY (id_unit, id_general_tag);


--
-- Name: many_unit_has_many_person many_unit_has_many_person_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_unit_has_many_person
    ADD CONSTRAINT many_unit_has_many_person_pk PRIMARY KEY (id_unit, id_person);


--
-- Name: metadata metadata_uq; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.metadata
    ADD CONSTRAINT metadata_uq UNIQUE (id_unit);


--
-- Name: motion_photo_additional motion_photo_additional_uq; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.motion_photo_additional
    ADD CONSTRAINT motion_photo_additional_uq UNIQUE (id_unit);


--
-- Name: normal_album normal_album_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.normal_album
    ADD CONSTRAINT normal_album_pk PRIMARY KEY (id);


--
-- Name: notification notification_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.notification
    ADD CONSTRAINT notification_primary PRIMARY KEY (id_user, event, target_id);


--
-- Name: one_filter_has_many_unit one_filter_has_many_unit_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.one_filter_has_many_unit
    ADD CONSTRAINT one_filter_has_many_unit_pk PRIMARY KEY (id_unit);


--
-- Name: share_permission passpharase_target_type_target_id_unique; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.share_permission
    ADD CONSTRAINT passpharase_target_type_target_id_unique UNIQUE (passphrase_share, target_type, target_id);


--
-- Name: share passphrase_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.share
    ADD CONSTRAINT passphrase_pk PRIMARY KEY (passphrase);


--
-- Name: person_group person_group_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.person_group
    ADD CONSTRAINT person_group_id_primary PRIMARY KEY (id);


--
-- Name: person person_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.person
    ADD CONSTRAINT person_id_primary PRIMARY KEY (id);


--
-- Name: person_item_count person_item_count_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.person_item_count
    ADD CONSTRAINT person_item_count_pk PRIMARY KEY (id_person, id_user);


--
-- Name: person_migration_mapping person_migration_mapping_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.person_migration_mapping
    ADD CONSTRAINT person_migration_mapping_primary PRIMARY KEY (id_user, id_person_source);


--
-- Name: photo_request photo_request_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.photo_request
    ADD CONSTRAINT photo_request_primary PRIMARY KEY (passphrase_share);


--
-- Name: folder_operation_error pk_folder_operation_error; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.folder_operation_error
    ADD CONSTRAINT pk_folder_operation_error PRIMARY KEY (id_task, target_id);


--
-- Name: folder_operation_task pk_id_folder; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.folder_operation_task
    ADD CONSTRAINT pk_id_folder PRIMARY KEY (id_folder);


--
-- Name: file_operation_task pk_id_task; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.file_operation_task
    ADD CONSTRAINT pk_id_task PRIMARY KEY (id_task);


--
-- Name: search_timeline search_timeline_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.search_timeline
    ADD CONSTRAINT search_timeline_pk PRIMARY KEY (id_item);


--
-- Name: share_permission share_permission_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.share_permission
    ADD CONSTRAINT share_permission_pk PRIMARY KEY (id);


--
-- Name: similar_group similar_group_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.similar_group
    ADD CONSTRAINT similar_group_pkey PRIMARY KEY (id);


--
-- Name: similar_hash similar_hash_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.similar_hash
    ADD CONSTRAINT similar_hash_pkey PRIMARY KEY (id_unit);


--
-- Name: similar_timeline similar_timeline_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.similar_timeline
    ADD CONSTRAINT similar_timeline_pkey PRIMARY KEY (id_unit, id_item, id_user);


--
-- Name: split_filename split_filename_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.split_filename
    ADD CONSTRAINT split_filename_pkey PRIMARY KEY (id_unit);


--
-- Name: takentime takentime_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.takentime
    ADD CONSTRAINT takentime_pk PRIMARY KEY (id);


--
-- Name: takentime takentime_uq; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.takentime
    ADD CONSTRAINT takentime_uq UNIQUE (takentime_day);


--
-- Name: team_library_folder_has_many_sorting team_library_folder_sorting_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.team_library_folder_has_many_sorting
    ADD CONSTRAINT team_library_folder_sorting_pk PRIMARY KEY (id_user, id_folder);


--
-- Name: team_library_group_permission team_library_group_permission_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.team_library_group_permission
    ADD CONSTRAINT team_library_group_permission_pk PRIMARY KEY (id_group);


--
-- Name: team_library_user_permission team_library_user_permission_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.team_library_user_permission
    ADD CONSTRAINT team_library_user_permission_pk PRIMARY KEY (id_user);


--
-- Name: thumbnail_version thumbnail_version_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.thumbnail_version
    ADD CONSTRAINT thumbnail_version_pkey PRIMARY KEY (id_unit);


--
-- Name: udc_statistic udc_statistic_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.udc_statistic
    ADD CONSTRAINT udc_statistic_pkey PRIMARY KEY (key, id_user);


--
-- Name: user_info uid_uk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_info
    ADD CONSTRAINT uid_uk UNIQUE (uid);


--
-- Name: unit unit_id_item_type_uk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.unit
    ADD CONSTRAINT unit_id_item_type_uk UNIQUE (id, item_type);


--
-- Name: unit unit_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.unit
    ADD CONSTRAINT unit_id_primary PRIMARY KEY (id);


--
-- Name: unit unit_id_takentime_fk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.unit
    ADD CONSTRAINT unit_id_takentime_fk UNIQUE (id, takentime);


--
-- Name: unit unit_item_fk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.unit
    ADD CONSTRAINT unit_item_fk UNIQUE (id, id_item);


--
-- Name: unit unit_major_fk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.unit
    ADD CONSTRAINT unit_major_fk UNIQUE (id, is_major);


--
-- Name: unit unit_uk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.unit
    ADD CONSTRAINT unit_uk UNIQUE (id, id_user);


--
-- Name: user_event_history_0 user_event_history_0_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_event_history_0
    ADD CONSTRAINT user_event_history_0_pkey PRIMARY KEY (version);


--
-- Name: user_event_history_10 user_event_history_10_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_event_history_10
    ADD CONSTRAINT user_event_history_10_pkey PRIMARY KEY (version);


--
-- Name: user_event_history_11 user_event_history_11_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_event_history_11
    ADD CONSTRAINT user_event_history_11_pkey PRIMARY KEY (version);


--
-- Name: user_event_history_12 user_event_history_12_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_event_history_12
    ADD CONSTRAINT user_event_history_12_pkey PRIMARY KEY (version);


--
-- Name: user_event_history_13 user_event_history_13_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_event_history_13
    ADD CONSTRAINT user_event_history_13_pkey PRIMARY KEY (version);


--
-- Name: user_event_history_1 user_event_history_1_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_event_history_1
    ADD CONSTRAINT user_event_history_1_pkey PRIMARY KEY (version);


--
-- Name: user_event_history_2 user_event_history_2_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_event_history_2
    ADD CONSTRAINT user_event_history_2_pkey PRIMARY KEY (version);


--
-- Name: user_event_history_3 user_event_history_3_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_event_history_3
    ADD CONSTRAINT user_event_history_3_pkey PRIMARY KEY (version);


--
-- Name: user_event_history_4 user_event_history_4_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_event_history_4
    ADD CONSTRAINT user_event_history_4_pkey PRIMARY KEY (version);


--
-- Name: user_event_history_5 user_event_history_5_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_event_history_5
    ADD CONSTRAINT user_event_history_5_pkey PRIMARY KEY (version);


--
-- Name: user_event_history_6 user_event_history_6_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_event_history_6
    ADD CONSTRAINT user_event_history_6_pkey PRIMARY KEY (version);


--
-- Name: user_event_history_7 user_event_history_7_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_event_history_7
    ADD CONSTRAINT user_event_history_7_pkey PRIMARY KEY (version);


--
-- Name: user_event_history_8 user_event_history_8_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_event_history_8
    ADD CONSTRAINT user_event_history_8_pkey PRIMARY KEY (version);


--
-- Name: user_event_history_9 user_event_history_9_pkey; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_event_history_9
    ADD CONSTRAINT user_event_history_9_pkey PRIMARY KEY (version);


--
-- Name: user_flag user_flag_pk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_flag
    ADD CONSTRAINT user_flag_pk PRIMARY KEY (id_user, flag);


--
-- Name: user_info user_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_info
    ADD CONSTRAINT user_id_primary PRIMARY KEY (id);


--
-- Name: administrative value_uk; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.administrative
    ADD CONSTRAINT value_uk UNIQUE (value);


--
-- Name: version_time version_id_primary; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.version_time
    ADD CONSTRAINT version_id_primary PRIMARY KEY (version);


--
-- Name: video_additional video_additional_uq; Type: CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.video_additional
    ADD CONSTRAINT video_additional_uq UNIQUE (id_unit);


--
-- Name: address_id_unit_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX address_id_unit_idx ON public.address USING btree (id_unit);


--
-- Name: address_id_user_lang_id_unit_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX address_id_user_lang_id_unit_idx ON public.address USING btree (id_user, lang, id_unit);


--
-- Name: adress_id_unit_lang_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX adress_id_unit_lang_idx ON public.address USING btree (id, lang);


--
-- Name: album_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX album_id_user_idx ON public.album USING btree (id_user);


--
-- Name: check_album_task_status_user_group_folder_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX check_album_task_status_user_group_folder_idx ON public.check_album_task USING btree (status, id_user, id_group, id_folder);


--
-- Name: cluster_id_person_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX cluster_id_person_idx ON public.cluster USING btree (id_person);


--
-- Name: concept_rawdata_need_migrate_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX concept_rawdata_need_migrate_idx ON public.concept_rawdata USING btree (need_migrate);


--
-- Name: concept_synonym_synonym_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX concept_synonym_synonym_idx ON public.concept_synonym USING btree (synonym);


--
-- Name: condition_album_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX condition_album_id_user_idx ON public.condition_album USING btree (id_user);


--
-- Name: convert_thumbnail_allocation_created_at_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX convert_thumbnail_allocation_created_at_idx ON public.convert_thumbnail_allocation USING btree (created_at);


--
-- Name: convert_thumbnail_allocation_id_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX convert_thumbnail_allocation_id_idx ON public.convert_thumbnail_allocation USING btree (id_user, id);


--
-- Name: convert_thumbnail_allocation_list_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX convert_thumbnail_allocation_list_idx ON public.convert_thumbnail_allocation USING btree (id_user, session_id);


--
-- Name: create_time_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX create_time_idx ON public.album USING btree (create_time);


--
-- Name: delete_album_version_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX delete_album_version_idx ON public.delete_album USING btree (version);


--
-- Name: delete_item_version_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX delete_item_version_idx ON public.delete_item USING btree (version);


--
-- Name: dsm_group_name_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX dsm_group_name_idx ON public.dsm_group USING btree (name);


--
-- Name: dsm_user_name_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX dsm_user_name_idx ON public.dsm_user USING btree (name);


--
-- Name: face_id_unit_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX face_id_unit_id_user_idx ON public.face USING btree (id_unit, id_user);


--
-- Name: face_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX face_id_user_idx ON public.face USING btree (id_user);


--
-- Name: face_person_group_list_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX face_person_group_list_idx ON public.face USING btree (id_user, id_person_group, id) WHERE (feature IS NOT NULL);


--
-- Name: face_person_group_migration_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX face_person_group_migration_idx ON public.face USING btree (id_user, id_person_group);


--
-- Name: face_unit_face_list_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX face_unit_face_list_idx ON public.face USING btree (id_user, id_unit, id) WHERE (is_manual = false);


--
-- Name: favorite_timeline_id_item_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX favorite_timeline_id_item_idx ON public.favorite_timeline USING btree (id_item);


--
-- Name: filter_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX filter_idx ON public.filter USING btree (id_user, filter_type, id_filter);


--
-- Name: folder_normalized_name_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX folder_normalized_name_idx ON public.folder USING btree (normalized_name);


--
-- Name: geocoding_grouping_key_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX geocoding_grouping_key_idx ON public.geocoding USING btree (grouping_key);


--
-- Name: geocoding_info_id_geocoding_lang_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX geocoding_info_id_geocoding_lang_idx ON public.geocoding_info USING btree (id_geocoding, lang);


--
-- Name: geocoding_level_1_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX geocoding_level_1_idx ON public.geocoding USING btree (level_1);


--
-- Name: geocoding_level_2_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX geocoding_level_2_idx ON public.geocoding USING btree (level_2);


--
-- Name: geocoding_level_3_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX geocoding_level_3_idx ON public.geocoding USING btree (level_3);


--
-- Name: geocoding_level_4_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX geocoding_level_4_idx ON public.geocoding USING btree (level_4);


--
-- Name: geocoding_level_5_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX geocoding_level_5_idx ON public.geocoding USING btree (level_5);


--
-- Name: geocoding_level_6_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX geocoding_level_6_idx ON public.geocoding USING btree (level_6);


--
-- Name: id_cluster_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX id_cluster_idx ON public.person_group USING btree (id_cluster);


--
-- Name: id_favorite_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX id_favorite_user_idx ON public.favorite_timeline USING gin (id_favorite_user);


--
-- Name: id_person_group_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX id_person_group_idx ON public.face USING btree (id_person_group);


--
-- Name: id_person_score_id_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX id_person_score_id_idx ON public.face USING btree (id_person, score DESC NULLS LAST, id);


--
-- Name: id_unit_id_user_id_favorite_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX id_unit_id_user_id_favorite_user_idx ON public.many_unit_has_many_favorite_user USING btree (id_unit, id_user, id_favorite_user);


--
-- Name: id_user_id_favorite_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX id_user_id_favorite_user_idx ON public.many_unit_has_many_favorite_user USING btree (id_user, id_favorite_user);


--
-- Name: id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX id_user_idx ON public.share_permission USING btree (id_user);


--
-- Name: id_user_target_type_target_id_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX id_user_target_type_target_id_idx ON public.share_permission USING btree (id_user, target_type, target_id);


--
-- Name: id_user_type_timestamp_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX id_user_type_timestamp_idx ON public.udc_event USING btree (id_user, type, "timestamp");


--
-- Name: index_queue_status_id_uk; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX index_queue_status_id_uk ON public.index_queue USING btree (status, type, id);


--
-- Name: index_queue_user_unit_type_uk; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX index_queue_user_unit_type_uk ON public.index_queue USING btree (id_user, id_unit, type);


--
-- Name: item_id_similar_group_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX item_id_similar_group_idx ON public.item USING btree (id_similar_group);


--
-- Name: item_is_similar_top_pick_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX item_is_similar_top_pick_idx ON public.item USING btree (is_similar_top_pick);


--
-- Name: item_type_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX item_type_idx ON public.item USING btree (type);


--
-- Name: item_type_order_func_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX item_type_order_func_idx ON public.item USING btree (public.display_item_type_order((type)::integer));


--
-- Name: many_unit_has_many_concept_id_user_id_concept_confidence_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX many_unit_has_many_concept_id_user_id_concept_confidence_idx ON public.many_unit_has_many_concept USING btree (id_user, id_concept, confidence);


--
-- Name: metadata_id_unit_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX metadata_id_unit_idx ON public.metadata USING btree (id_unit);


--
-- Name: normal_album_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX normal_album_id_user_idx ON public.normal_album USING btree (id_user);


--
-- Name: normal_album_id_user_status_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX normal_album_id_user_status_idx ON public.normal_album USING btree (id_user, status);


--
-- Name: notification_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX notification_idx ON public.notification USING btree (event);


--
-- Name: person_group_cluster_list_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX person_group_cluster_list_idx ON public.person_group USING btree (id_user, id_cluster, id);


--
-- Name: person_group_cluster_migration_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX person_group_cluster_migration_idx ON public.person_group USING btree (id_user, id_cluster);


--
-- Name: ref_id_unit_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX ref_id_unit_id_user_idx ON public.face USING btree (ref_id_unit, id_user);


--
-- Name: search_timeline_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX search_timeline_idx ON public.search_timeline USING btree (takentime);


--
-- Name: similar_hash_id_user_skip_need_action_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX similar_hash_id_user_skip_need_action_idx ON public.similar_hash USING btree (id_user, skip, need_action);


--
-- Name: similar_hash_skip_need_action_array_length_takentime_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX similar_hash_skip_need_action_array_length_takentime_idx ON public.similar_hash USING btree (skip, need_action, array_length(pdq_hash, 1), takentime);


--
-- Name: similar_timeline_id_item_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX similar_timeline_id_item_idx ON public.similar_timeline USING btree (id_item);


--
-- Name: takentime_day_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX takentime_day_idx ON public.takentime USING btree (takentime_day);


--
-- Name: takentime_month_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX takentime_month_idx ON public.takentime USING btree (takentime_month);


--
-- Name: takentime_takentime_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX takentime_takentime_idx ON public.takentime USING btree (takentime);


--
-- Name: target_type_target_id_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX target_type_target_id_idx ON public.share_permission USING btree (target_type, target_id);


--
-- Name: thumbnail_id_type_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX thumbnail_id_type_idx ON public.thumbnail USING btree (id_unit, type);


--
-- Name: time_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX time_idx ON public.version_time USING btree (modified_time);


--
-- Name: type_status_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX type_status_idx ON public.thumbnail USING btree (type, status);


--
-- Name: unit_id_folder_filename_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX unit_id_folder_filename_idx ON public.unit USING btree (id_folder, filename);


--
-- Name: unit_id_folder_normalized_filename_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX unit_id_folder_normalized_filename_idx ON public.unit USING btree (id_folder, normalized_filename);


--
-- Name: unit_id_item_id_geocoding_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX unit_id_item_id_geocoding_idx ON public.unit USING btree (id_item, id_geocoding);


--
-- Name: unit_id_item_is_major_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX unit_id_item_is_major_id_user_idx ON public.unit USING btree (id_item, is_major, id_user);


--
-- Name: unit_id_user_createtime_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX unit_id_user_createtime_idx ON public.unit USING btree (id_user, createtime);


--
-- Name: unit_id_user_id_folder_id_desc_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX unit_id_user_id_folder_id_desc_idx ON public.unit USING btree (id_user, id_folder, id DESC);


--
-- Name: unit_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX unit_id_user_idx ON public.unit USING btree (id_user);


--
-- Name: unit_id_user_takentime_desc_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX unit_id_user_takentime_desc_idx ON public.unit USING btree (id_user, takentime DESC NULLS LAST);


--
-- Name: unit_id_user_takentime_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX unit_id_user_takentime_idx ON public.unit USING btree (id_user, takentime);


--
-- Name: unit_index_stage_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX unit_index_stage_idx ON public.unit USING btree (index_stage);


--
-- Name: unit_item_type_order_func_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX unit_item_type_order_func_idx ON public.unit USING btree (public.display_item_type_order((item_type)::integer));


--
-- Name: unit_type_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX unit_type_idx ON public.unit USING btree (type);


--
-- Name: user_event_history_0_version_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX user_event_history_0_version_id_user_idx ON public.user_event_history_0 USING btree (id_user, version);


--
-- Name: user_event_history_10_version_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX user_event_history_10_version_id_user_idx ON public.user_event_history_10 USING btree (id_user, version);


--
-- Name: user_event_history_11_version_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX user_event_history_11_version_id_user_idx ON public.user_event_history_11 USING btree (id_user, version);


--
-- Name: user_event_history_12_version_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX user_event_history_12_version_id_user_idx ON public.user_event_history_12 USING btree (id_user, version);


--
-- Name: user_event_history_13_version_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX user_event_history_13_version_id_user_idx ON public.user_event_history_13 USING btree (id_user, version);


--
-- Name: user_event_history_1_version_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX user_event_history_1_version_id_user_idx ON public.user_event_history_1 USING btree (id_user, version);


--
-- Name: user_event_history_2_version_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX user_event_history_2_version_id_user_idx ON public.user_event_history_2 USING btree (id_user, version);


--
-- Name: user_event_history_3_version_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX user_event_history_3_version_id_user_idx ON public.user_event_history_3 USING btree (id_user, version);


--
-- Name: user_event_history_4_version_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX user_event_history_4_version_id_user_idx ON public.user_event_history_4 USING btree (id_user, version);


--
-- Name: user_event_history_5_version_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX user_event_history_5_version_id_user_idx ON public.user_event_history_5 USING btree (id_user, version);


--
-- Name: user_event_history_6_version_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX user_event_history_6_version_id_user_idx ON public.user_event_history_6 USING btree (id_user, version);


--
-- Name: user_event_history_7_version_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX user_event_history_7_version_id_user_idx ON public.user_event_history_7 USING btree (id_user, version);


--
-- Name: user_event_history_8_version_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX user_event_history_8_version_id_user_idx ON public.user_event_history_8 USING btree (id_user, version);


--
-- Name: user_event_history_9_version_id_user_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX user_event_history_9_version_id_user_idx ON public.user_event_history_9 USING btree (id_user, version);


--
-- Name: version_time_0_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE UNIQUE INDEX version_time_0_idx ON public.version_time_0 USING btree (version, modified_time);


--
-- Name: version_time_1_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE UNIQUE INDEX version_time_1_idx ON public.version_time_1 USING btree (version, modified_time);


--
-- Name: version_time_2_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE UNIQUE INDEX version_time_2_idx ON public.version_time_2 USING btree (version, modified_time);


--
-- Name: version_time_3_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE UNIQUE INDEX version_time_3_idx ON public.version_time_3 USING btree (version, modified_time);


--
-- Name: video_additional_codec_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX video_additional_codec_idx ON public.video_additional USING btree (public.get_json_value(video_info, 'video_codec'::text));


--
-- Name: video_convert_id_unit_idx; Type: INDEX; Schema: public; Owner: SynologyPhotos
--

CREATE INDEX video_convert_id_unit_idx ON public.video_convert USING btree (id_unit);


--
-- Name: concept_timeline_view _RETURN; Type: RULE; Schema: public; Owner: SynologyPhotos
--

CREATE OR REPLACE VIEW public.concept_timeline_view AS
 SELECT u.id_item,
    u.id_user,
    u.item_type,
    u.type AS unit_type,
    u.id AS id_unit,
    array_agg(DISTINCT r.id_concept) AS id_concept,
    u.takentime
   FROM (public.unit u
     JOIN public.many_unit_has_many_concept r ON ((u.id = r.id_unit)))
  WHERE (u.is_major = true)
  GROUP BY u.id_user, u.id;


--
-- Name: general_tag_timeline_view _RETURN; Type: RULE; Schema: public; Owner: SynologyPhotos
--

CREATE OR REPLACE VIEW public.general_tag_timeline_view AS
 SELECT u.id_item,
    u.id_user,
    u.item_type,
    u.type AS unit_type,
    u.id AS id_unit,
    array_agg(DISTINCT r.id_general_tag) AS id_general_tag,
    u.takentime
   FROM (public.unit u
     JOIN public.many_unit_has_many_general_tag r ON ((u.id = r.id_unit)))
  WHERE (u.is_major = true)
  GROUP BY u.id_user, u.id;


--
-- Name: person_timeline_view _RETURN; Type: RULE; Schema: public; Owner: SynologyPhotos
--

CREATE OR REPLACE VIEW public.person_timeline_view AS
 SELECT u.id_item,
    u.id_user,
    u.item_type,
    u.type AS unit_type,
    u.id AS id_unit,
    array_agg(DISTINCT f.id_person) AS id_person,
    u.takentime
   FROM (public.unit u
     JOIN public.face f ON ((u.id = f.id_unit)))
  WHERE (u.is_major = true)
  GROUP BY u.id_user, u.id;


--
-- Name: face drop_face_lo_on_delete; Type: RULE; Schema: public; Owner: SynologyPhotos
--

CREATE RULE drop_face_lo_on_delete AS
    ON DELETE TO public.face DO  SELECT lo_unlink(old.picture) AS lo_unlink;


--
-- Name: face drop_face_lo_on_update; Type: RULE; Schema: public; Owner: SynologyPhotos
--

CREATE RULE drop_face_lo_on_update AS
    ON UPDATE TO public.face
   WHERE (new.picture <> old.picture) DO  SELECT lo_unlink(old.picture) AS lo_unlink;


--
-- Name: thumb_preview drop_preview_lo_on_delete; Type: RULE; Schema: public; Owner: SynologyPhotos
--

CREATE RULE drop_preview_lo_on_delete AS
    ON DELETE TO public.thumb_preview DO  SELECT lo_unlink(old.picture) AS lo_unlink;


--
-- Name: thumb_preview drop_preview_lo_on_update; Type: RULE; Schema: public; Owner: SynologyPhotos
--

CREATE RULE drop_preview_lo_on_update AS
    ON UPDATE TO public.thumb_preview
   WHERE (new.picture <> old.picture) DO  SELECT lo_unlink(old.picture) AS lo_unlink;


--
-- Name: condition_album condition_delete_cascade_to_share_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER condition_delete_cascade_to_share_trigger AFTER DELETE OR UPDATE ON public.condition_album FOR EACH ROW EXECUTE PROCEDURE public.delete_normal_album_after_trigger_func();


--
-- Name: user_info create_version_related_table_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER create_version_related_table_trigger AFTER INSERT ON public.user_info FOR EACH ROW EXECUTE PROCEDURE public.create_version_related_table_trigger_func();


--
-- Name: version_time_0 delete_expired_version_time_0_data_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER delete_expired_version_time_0_data_trigger BEFORE INSERT ON public.version_time_0 FOR EACH ROW EXECUTE PROCEDURE public.delete_expired_version_time_data_func();


--
-- Name: version_time_1 delete_expired_version_time_1_data_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER delete_expired_version_time_1_data_trigger BEFORE INSERT ON public.version_time_1 FOR EACH ROW EXECUTE PROCEDURE public.delete_expired_version_time_data_func();


--
-- Name: version_time_2 delete_expired_version_time_2_data_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER delete_expired_version_time_2_data_trigger BEFORE INSERT ON public.version_time_2 FOR EACH ROW EXECUTE PROCEDURE public.delete_expired_version_time_data_func();


--
-- Name: version_time_3 delete_expired_version_time_3_data_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER delete_expired_version_time_3_data_trigger BEFORE INSERT ON public.version_time_3 FOR EACH ROW EXECUTE PROCEDURE public.delete_expired_version_time_data_func();


--
-- Name: version_time delete_expired_version_time_data_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER delete_expired_version_time_data_trigger BEFORE INSERT ON public.version_time FOR EACH ROW EXECUTE PROCEDURE public.delete_expired_version_time_data_func();


--
-- Name: face delete_face_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER delete_face_trigger AFTER DELETE ON public.face FOR EACH ROW EXECUTE PROCEDURE public.delete_face_trigger_func();


--
-- Name: group_info delete_group_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER delete_group_trigger AFTER DELETE ON public.group_info FOR EACH ROW EXECUTE PROCEDURE public.delete_group_func();


--
-- Name: unit delete_index_task_after_delete_unit_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER delete_index_task_after_delete_unit_trigger AFTER DELETE ON public.unit FOR EACH ROW EXECUTE PROCEDURE public.delete_index_task_after_delete_unit();


--
-- Name: many_item_has_many_normal_album delete_item_to_update_normal_album_trigger_func; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER delete_item_to_update_normal_album_trigger_func AFTER DELETE ON public.many_item_has_many_normal_album FOR EACH ROW EXECUTE PROCEDURE public.delete_item_to_update_normal_album_trigger_func();


--
-- Name: item delete_item_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER delete_item_trigger AFTER DELETE ON public.item FOR EACH ROW EXECUTE PROCEDURE public.delete_item_func();


--
-- Name: share delete_share_cascade_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER delete_share_cascade_trigger AFTER DELETE ON public.share FOR EACH ROW EXECUTE PROCEDURE public.delete_share_cascade_func();


--
-- Name: item delete_similar_timeline_after_item_update_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER delete_similar_timeline_after_item_update_trigger AFTER UPDATE OF is_similar_top_pick ON public.item FOR EACH ROW EXECUTE PROCEDURE public.delete_similar_timeline_after_item_update_func();


--
-- Name: user_info delete_user_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER delete_user_trigger AFTER DELETE ON public.user_info FOR EACH ROW EXECUTE PROCEDURE public.delete_user_func();


--
-- Name: face face_update_unit_version_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER face_update_unit_version_trigger AFTER UPDATE ON public.face FOR EACH ROW EXECUTE PROCEDURE public.face_update_unit_version_func();


--
-- Name: many_unit_has_many_concept increase_concept_album_additional; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER increase_concept_album_additional AFTER INSERT ON public.many_unit_has_many_concept FOR EACH ROW EXECUTE PROCEDURE public.increase_concept_album_additional();


--
-- Name: user_info init_user_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER init_user_trigger AFTER INSERT ON public.user_info FOR EACH ROW EXECUTE PROCEDURE public.init_user_func();


--
-- Name: item insert_similar_timeline_after_item_update_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER insert_similar_timeline_after_item_update_trigger AFTER UPDATE OF is_similar_top_pick, id_similar_group ON public.item FOR EACH ROW EXECUTE PROCEDURE public.insert_similar_timeline_after_item_update_func();


--
-- Name: metadata metadata_update_unit_version_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER metadata_update_unit_version_trigger AFTER UPDATE ON public.metadata FOR EACH ROW EXECUTE PROCEDURE public.metadata_update_unit_version_func();


--
-- Name: normal_album normal_delete_cascade_to_share_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER normal_delete_cascade_to_share_trigger AFTER DELETE OR UPDATE ON public.normal_album FOR EACH ROW EXECUTE PROCEDURE public.delete_normal_album_after_trigger_func();


--
-- Name: share_permission share_permission_update_album_version_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER share_permission_update_album_version_trigger AFTER INSERT OR DELETE OR UPDATE ON public.share_permission FOR EACH ROW EXECUTE PROCEDURE public.share_permission_update_album_version_func();


--
-- Name: share share_update_album_version_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER share_update_album_version_trigger AFTER UPDATE ON public.share FOR EACH ROW EXECUTE PROCEDURE public.share_update_album_version_func();


--
-- Name: many_unit_has_many_general_tag tag_update_unit_version_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER tag_update_unit_version_trigger AFTER INSERT OR DELETE ON public.many_unit_has_many_general_tag FOR EACH ROW EXECUTE PROCEDURE public.tag_update_unit_version_func();


--
-- Name: unit unit_update_takentime_cascade_to_condition_album_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER unit_update_takentime_cascade_to_condition_album_trigger AFTER UPDATE OF takentime ON public.unit FOR EACH ROW EXECUTE PROCEDURE public.update_condition_album_time_trigger_func();


--
-- Name: unit unit_update_takentime_cascade_to_noraml_album_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER unit_update_takentime_cascade_to_noraml_album_trigger AFTER UPDATE OF takentime ON public.unit FOR EACH ROW EXECUTE PROCEDURE public.update_normal_album_time_trigger_func();


--
-- Name: unit update_condition_album_after_delete_unit_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_condition_album_after_delete_unit_trigger AFTER DELETE ON public.unit FOR EACH ROW EXECUTE PROCEDURE public.update_condition_album_time_trigger_func();


--
-- Name: condition_album update_condition_album_version_func; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_condition_album_version_func BEFORE INSERT OR UPDATE ON public.condition_album FOR EACH ROW EXECUTE PROCEDURE public.update_condition_album_version_func();


--
-- Name: face update_face_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_face_trigger AFTER UPDATE ON public.face FOR EACH ROW EXECUTE PROCEDURE public.update_face_func();


--
-- Name: many_unit_has_many_concept update_filter_after_many_unit_has_many_concept_delete_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_filter_after_many_unit_has_many_concept_delete_trigger AFTER DELETE ON public.many_unit_has_many_concept FOR EACH ROW EXECUTE PROCEDURE public.update_filter_after_many_unit_has_many_concept_delete_func();


--
-- Name: unit update_geocoding_after_delete_unit_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_geocoding_after_delete_unit_trigger AFTER DELETE ON public.unit FOR EACH ROW EXECUTE PROCEDURE public.delete_nonexisting_geocoding_after_delete_unit();


--
-- Name: filter update_many_unit_has_many_administrative_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_many_unit_has_many_administrative_trigger AFTER INSERT OR DELETE OR UPDATE ON public.filter FOR EACH ROW EXECUTE PROCEDURE public.update_many_unit_has_many_administrative_func();


--
-- Name: filter update_many_unit_has_many_person_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_many_unit_has_many_person_trigger AFTER INSERT OR DELETE OR UPDATE ON public.filter FOR EACH ROW EXECUTE PROCEDURE public.update_many_unit_has_many_person_func();


--
-- Name: normal_album update_normal_album_version_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_normal_album_version_trigger BEFORE INSERT OR UPDATE ON public.normal_album FOR EACH ROW EXECUTE PROCEDURE public.update_normal_album_version_func();


--
-- Name: unit update_one_filter_has_many_unit_is_major_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_one_filter_has_many_unit_is_major_trigger AFTER UPDATE OF is_major ON public.unit FOR EACH ROW EXECUTE PROCEDURE public.update_one_filter_has_many_unit_is_major_func();


--
-- Name: filter update_one_filter_has_many_unit_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_one_filter_has_many_unit_trigger AFTER INSERT OR DELETE OR UPDATE ON public.filter FOR EACH ROW EXECUTE PROCEDURE public.update_one_filter_has_many_unit_func();


--
-- Name: item update_similar_timeline_after_item_update_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_similar_timeline_after_item_update_trigger AFTER UPDATE OF id_similar_group ON public.item FOR EACH ROW EXECUTE PROCEDURE public.update_similar_timeline_after_item_update_func();


--
-- Name: similar_group update_similar_timeline_after_similar_group_update_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_similar_timeline_after_similar_group_update_trigger AFTER UPDATE OF item_count ON public.similar_group FOR EACH ROW EXECUTE PROCEDURE public.update_similar_timeline_after_similar_group_update_func();


--
-- Name: unit update_similar_timeline_after_unit_insert_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_similar_timeline_after_unit_insert_trigger AFTER INSERT ON public.unit FOR EACH ROW EXECUTE PROCEDURE public.update_similar_timeline_after_unit_insert_func();


--
-- Name: many_unit_has_many_general_tag update_tag_ref_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_tag_ref_trigger AFTER INSERT OR DELETE OR UPDATE ON public.many_unit_has_many_general_tag FOR EACH ROW EXECUTE PROCEDURE public.update_tag_ref_count_func();


--
-- Name: unit update_unit_after_delete_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_unit_after_delete_trigger AFTER DELETE OR UPDATE ON public.unit FOR EACH ROW EXECUTE PROCEDURE public.delete_unit_version_func();


--
-- Name: unit update_unit_version_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_unit_version_trigger BEFORE INSERT OR UPDATE ON public.unit FOR EACH ROW EXECUTE PROCEDURE public.update_unit_version_func();


--
-- Name: delete_item update_user_flag_after_delete_item_update_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_user_flag_after_delete_item_update_trigger AFTER INSERT OR UPDATE ON public.delete_item FOR EACH ROW EXECUTE PROCEDURE public.update_user_flag_after_delete_item_update_func();


--
-- Name: unit update_user_flag_after_live_photo_update_insert_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_user_flag_after_live_photo_update_insert_trigger AFTER INSERT ON public.unit REFERENCING NEW TABLE AS new_table FOR EACH STATEMENT EXECUTE PROCEDURE public.update_user_flag_after_live_photo_update_func();


--
-- Name: unit update_user_flag_after_live_photo_update_update_trigger; Type: TRIGGER; Schema: public; Owner: SynologyPhotos
--

CREATE TRIGGER update_user_flag_after_live_photo_update_update_trigger AFTER UPDATE ON public.unit REFERENCING OLD TABLE AS old_table NEW TABLE AS new_table FOR EACH STATEMENT EXECUTE PROCEDURE public.update_user_flag_after_live_photo_update_func();


--
-- Name: address address_composite_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.address
    ADD CONSTRAINT address_composite_unit_fk FOREIGN KEY (id_unit, id_user) REFERENCES public.unit(id, id_user) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: address address_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.address
    ADD CONSTRAINT address_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: address address_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.address
    ADD CONSTRAINT address_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: album album_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.album
    ADD CONSTRAINT album_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: photo_request album_passphrase_share_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.photo_request
    ADD CONSTRAINT album_passphrase_share_fk FOREIGN KEY (album_passphrase_share) REFERENCES public.share(passphrase) MATCH FULL ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: album album_share_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.album
    ADD CONSTRAINT album_share_fk FOREIGN KEY (passphrase_share) REFERENCES public.share(passphrase) MATCH FULL ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: async_db_migration_task async_db_migration_task_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.async_db_migration_task
    ADD CONSTRAINT async_db_migration_task_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: burst_additional burst_additional_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.burst_additional
    ADD CONSTRAINT burst_additional_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: burst_additional burst_additional_user_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.burst_additional
    ADD CONSTRAINT burst_additional_user_id_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL;


--
-- Name: person_group cluster_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.person_group
    ADD CONSTRAINT cluster_fk FOREIGN KEY (id_cluster) REFERENCES public.cluster(id) MATCH FULL ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: cluster cluster_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.cluster
    ADD CONSTRAINT cluster_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: cluster cluster_person_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.cluster
    ADD CONSTRAINT cluster_person_fk FOREIGN KEY (id_person) REFERENCES public.person(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: concept_album_additional concept_album_additional_concept_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.concept_album_additional
    ADD CONSTRAINT concept_album_additional_concept_fk FOREIGN KEY (id_concept) REFERENCES public.concept(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: concept_rawdata concept_rawdata_composite_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.concept_rawdata
    ADD CONSTRAINT concept_rawdata_composite_unit_fk FOREIGN KEY (id_unit, id_user) REFERENCES public.unit(id, id_user) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: concept_synonym concept_synonym_concept_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.concept_synonym
    ADD CONSTRAINT concept_synonym_concept_fk FOREIGN KEY (id_concept) REFERENCES public.concept(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: concept_threshold concept_threshold_concept_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.concept_threshold
    ADD CONSTRAINT concept_threshold_concept_fk FOREIGN KEY (id_concept) REFERENCES public.concept(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: condition_album condition_album_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.condition_album
    ADD CONSTRAINT condition_album_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: condition_album condition_album_share_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.condition_album
    ADD CONSTRAINT condition_album_share_fk FOREIGN KEY (passphrase_share) REFERENCES public.share(passphrase) MATCH FULL ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: convert_thumbnail_allocation convert_thumbnail_allocation_unit_fkey; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.convert_thumbnail_allocation
    ADD CONSTRAINT convert_thumbnail_allocation_unit_fkey FOREIGN KEY (id, id_user) REFERENCES public.unit(id, id_user) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person cover_id_face; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.person
    ADD CONSTRAINT cover_id_face FOREIGN KEY (cover) REFERENCES public.face(id) MATCH FULL ON UPDATE RESTRICT ON DELETE SET NULL DEFERRABLE;


--
-- Name: delete_album delete_album_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.delete_album
    ADD CONSTRAINT delete_album_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: delete_condition_album delete_condition_album_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.delete_condition_album
    ADD CONSTRAINT delete_condition_album_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: delete_item delete_item_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.delete_item
    ADD CONSTRAINT delete_item_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: face face_composite_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.face
    ADD CONSTRAINT face_composite_unit_fk FOREIGN KEY (ref_id_unit, id_user) REFERENCES public.unit(id, id_user) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: face face_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.face
    ADD CONSTRAINT face_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: face face_person_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.face
    ADD CONSTRAINT face_person_fk FOREIGN KEY (id_person) REFERENCES public.person(id) MATCH FULL ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: favorite_timeline favorite_timeline_unit_id_user_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.favorite_timeline
    ADD CONSTRAINT favorite_timeline_unit_id_user_id_fk FOREIGN KEY (id_unit, id_user) REFERENCES public.unit(id, id_user) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: file_operation_error file_operation_error_id_task_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.file_operation_error
    ADD CONSTRAINT file_operation_error_id_task_fk FOREIGN KEY (id_task) REFERENCES public.background_task(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: file_operation_task file_operation_task_id_task_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.file_operation_task
    ADD CONSTRAINT file_operation_task_id_task_fk FOREIGN KEY (id_task) REFERENCES public.background_task(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: filter filter_composite_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.filter
    ADD CONSTRAINT filter_composite_unit_fk FOREIGN KEY (id_unit, id_user) REFERENCES public.unit(id, id_user) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: filter filter_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.filter
    ADD CONSTRAINT filter_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: filter filter_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.filter
    ADD CONSTRAINT filter_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: folder folder_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.folder
    ADD CONSTRAINT folder_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: folder_operation_error folder_operation_error_fk_id_task; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.folder_operation_error
    ADD CONSTRAINT folder_operation_error_fk_id_task FOREIGN KEY (id_task) REFERENCES public.background_task(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: folder_operation_task folder_operation_task_fk_id_task; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.folder_operation_task
    ADD CONSTRAINT folder_operation_task_fk_id_task FOREIGN KEY (id_task) REFERENCES public.background_task(id);


--
-- Name: folder folder_parent_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.folder
    ADD CONSTRAINT folder_parent_fk FOREIGN KEY (parent) REFERENCES public.folder(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: folder folder_share_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.folder
    ADD CONSTRAINT folder_share_fk FOREIGN KEY (passphrase_share) REFERENCES public.share(passphrase) MATCH FULL ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: many_unit_has_many_general_tag general_tag_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_unit_has_many_general_tag
    ADD CONSTRAINT general_tag_fk FOREIGN KEY (id_general_tag) REFERENCES public.general_tag(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: geocoding_info geocoding_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.geocoding_info
    ADD CONSTRAINT geocoding_fk FOREIGN KEY (id_geocoding) REFERENCES public.geocoding(id) MATCH FULL ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: geocoding geocoding_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.geocoding
    ADD CONSTRAINT geocoding_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: geocoding_info geocoding_info_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.geocoding_info
    ADD CONSTRAINT geocoding_info_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: photo_request id_album_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.photo_request
    ADD CONSTRAINT id_album_fk FOREIGN KEY (id_album) REFERENCES public.normal_album(id) MATCH FULL ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: team_library_group_permission id_group_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.team_library_group_permission
    ADD CONSTRAINT id_group_fk FOREIGN KEY (id_group) REFERENCES public.group_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: item id_similar_group_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.item
    ADD CONSTRAINT id_similar_group_fk FOREIGN KEY (id_similar_group) REFERENCES public.similar_group(id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: unit item_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.unit
    ADD CONSTRAINT item_fk FOREIGN KEY (id_item) REFERENCES public.item(id) MATCH FULL ON UPDATE RESTRICT ON DELETE CASCADE;


--
-- Name: many_item_has_many_normal_album item_provider_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_item_has_many_normal_album
    ADD CONSTRAINT item_provider_id_user_fk FOREIGN KEY (item_provider_id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: item item_user_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.item
    ADD CONSTRAINT item_user_id_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: geocoding level_1_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.geocoding
    ADD CONSTRAINT level_1_fk FOREIGN KEY (level_1) REFERENCES public.administrative(id) MATCH FULL ON UPDATE RESTRICT ON DELETE SET NULL;


--
-- Name: geocoding level_2_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.geocoding
    ADD CONSTRAINT level_2_fk FOREIGN KEY (level_2) REFERENCES public.administrative(id) MATCH FULL ON UPDATE RESTRICT ON DELETE SET NULL;


--
-- Name: geocoding level_3_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.geocoding
    ADD CONSTRAINT level_3_fk FOREIGN KEY (level_3) REFERENCES public.administrative(id) MATCH FULL ON UPDATE RESTRICT ON DELETE SET NULL;


--
-- Name: geocoding level_4_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.geocoding
    ADD CONSTRAINT level_4_fk FOREIGN KEY (level_4) REFERENCES public.administrative(id) MATCH FULL ON UPDATE RESTRICT ON DELETE SET NULL;


--
-- Name: geocoding level_5_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.geocoding
    ADD CONSTRAINT level_5_fk FOREIGN KEY (level_5) REFERENCES public.administrative(id) MATCH FULL ON UPDATE RESTRICT ON DELETE SET NULL;


--
-- Name: geocoding level_6_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.geocoding
    ADD CONSTRAINT level_6_fk FOREIGN KEY (level_6) REFERENCES public.administrative(id) MATCH FULL ON UPDATE RESTRICT ON DELETE SET NULL;


--
-- Name: address level_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.address
    ADD CONSTRAINT level_fk FOREIGN KEY (level) REFERENCES public.administrative(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: live_additional live_additional_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.live_additional
    ADD CONSTRAINT live_additional_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: many_item_has_many_normal_album many_item_has_many_normal_album_album_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_item_has_many_normal_album
    ADD CONSTRAINT many_item_has_many_normal_album_album_id_user_fk FOREIGN KEY (album_id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: many_item_has_many_normal_album many_item_has_many_normal_album_item_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_item_has_many_normal_album
    ADD CONSTRAINT many_item_has_many_normal_album_item_fk FOREIGN KEY (id_item) REFERENCES public.item(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: many_unit_has_many_administrative many_unit_has_many_administrative_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_unit_has_many_administrative
    ADD CONSTRAINT many_unit_has_many_administrative_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: many_unit_has_many_concept many_unit_has_many_concept_composite_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_unit_has_many_concept
    ADD CONSTRAINT many_unit_has_many_concept_composite_unit_fk FOREIGN KEY (id_unit, id_user) REFERENCES public.unit(id, id_user) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: many_unit_has_many_concept many_unit_has_many_concept_concept_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_unit_has_many_concept
    ADD CONSTRAINT many_unit_has_many_concept_concept_fk FOREIGN KEY (id_concept) REFERENCES public.concept(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: many_unit_has_many_favorite_user many_unit_has_many_favorite_user_unit_id_user_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_unit_has_many_favorite_user
    ADD CONSTRAINT many_unit_has_many_favorite_user_unit_id_user_id_fk FOREIGN KEY (id_unit, id_user) REFERENCES public.unit(id, id_user) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: many_unit_has_many_general_tag many_unit_has_many_general_tag_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_unit_has_many_general_tag
    ADD CONSTRAINT many_unit_has_many_general_tag_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: many_unit_has_many_person many_unit_has_many_person_composite_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_unit_has_many_person
    ADD CONSTRAINT many_unit_has_many_person_composite_unit_fk FOREIGN KEY (id_unit, id_user) REFERENCES public.unit(id, id_user) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: many_unit_has_many_person many_unit_has_many_person_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_unit_has_many_person
    ADD CONSTRAINT many_unit_has_many_person_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: metadata metadata_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.metadata
    ADD CONSTRAINT metadata_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: motion_photo_additional motion_photo_additional_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.motion_photo_additional
    ADD CONSTRAINT motion_photo_additional_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: many_item_has_many_normal_album normal_album_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.many_item_has_many_normal_album
    ADD CONSTRAINT normal_album_fk FOREIGN KEY (id_normal_album) REFERENCES public.normal_album(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: normal_album normal_album_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.normal_album
    ADD CONSTRAINT normal_album_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: normal_album normal_album_share_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.normal_album
    ADD CONSTRAINT normal_album_share_fk FOREIGN KEY (passphrase_share) REFERENCES public.share(passphrase) MATCH FULL ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: notification notification_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.notification
    ADD CONSTRAINT notification_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: one_filter_has_many_unit one_filter_has_many_unit_composite_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.one_filter_has_many_unit
    ADD CONSTRAINT one_filter_has_many_unit_composite_unit_fk FOREIGN KEY (id_unit, id_user) REFERENCES public.unit(id, id_user) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: one_filter_has_many_unit one_filter_has_many_unit_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.one_filter_has_many_unit
    ADD CONSTRAINT one_filter_has_many_unit_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: photo_request passphrase_share_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.photo_request
    ADD CONSTRAINT passphrase_share_fk FOREIGN KEY (passphrase_share) REFERENCES public.share(passphrase) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: face person_group_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.face
    ADD CONSTRAINT person_group_fk FOREIGN KEY (id_person_group) REFERENCES public.person_group(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person_group person_group_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.person_group
    ADD CONSTRAINT person_group_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person person_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.person
    ADD CONSTRAINT person_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person_item_count person_item_count_person_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.person_item_count
    ADD CONSTRAINT person_item_count_person_fk FOREIGN KEY (id_person) REFERENCES public.person(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: person_migration_mapping person_migration_mapping_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.person_migration_mapping
    ADD CONSTRAINT person_migration_mapping_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: face person_ref_id_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.face
    ADD CONSTRAINT person_ref_id_unit_fk FOREIGN KEY (ref_id_unit) REFERENCES public.unit(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: photo_request photo_request_folder_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.photo_request
    ADD CONSTRAINT photo_request_folder_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: photo_request photo_request_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.photo_request
    ADD CONSTRAINT photo_request_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: share share_id_user_info_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.share
    ADD CONSTRAINT share_id_user_info_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: share_permission share_permission_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.share_permission
    ADD CONSTRAINT share_permission_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: share_permission share_permission_share_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.share_permission
    ADD CONSTRAINT share_permission_share_fk FOREIGN KEY (passphrase_share) REFERENCES public.share(passphrase) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: similar_group similar_group_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.similar_group
    ADD CONSTRAINT similar_group_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: similar_hash similar_hash_id_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.similar_hash
    ADD CONSTRAINT similar_hash_id_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) ON DELETE CASCADE;


--
-- Name: similar_hash similar_hash_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.similar_hash
    ADD CONSTRAINT similar_hash_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: similar_hash similar_hash_unit_item_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.similar_hash
    ADD CONSTRAINT similar_hash_unit_item_fk FOREIGN KEY (id_unit, id_item) REFERENCES public.unit(id, id_item) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: similar_hash similar_hash_unit_major_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.similar_hash
    ADD CONSTRAINT similar_hash_unit_major_fk FOREIGN KEY (id_unit, is_major) REFERENCES public.unit(id, is_major) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: similar_timeline similar_timeline_composite_unit_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.similar_timeline
    ADD CONSTRAINT similar_timeline_composite_unit_user_fk FOREIGN KEY (id_unit, id_user) REFERENCES public.unit(id, id_user) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: similar_timeline similar_timeline_item_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.similar_timeline
    ADD CONSTRAINT similar_timeline_item_fk FOREIGN KEY (id_item) REFERENCES public.item(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: similar_timeline similar_unit_item_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.similar_timeline
    ADD CONSTRAINT similar_unit_item_fk FOREIGN KEY (id_unit, id_item) REFERENCES public.unit(id, id_item) ON UPDATE CASCADE;


--
-- Name: similar_timeline similar_unit_takentime_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.similar_timeline
    ADD CONSTRAINT similar_unit_takentime_fk FOREIGN KEY (id_unit, takentime) REFERENCES public.unit(id, takentime) ON UPDATE CASCADE;


--
-- Name: split_filename split_filename_id_unit_fkey; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.split_filename
    ADD CONSTRAINT split_filename_id_unit_fkey FOREIGN KEY (id_unit) REFERENCES public.unit(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: team_library_folder_has_many_sorting team_library_folder_has_many_sorting_folder_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.team_library_folder_has_many_sorting
    ADD CONSTRAINT team_library_folder_has_many_sorting_folder_fk FOREIGN KEY (id_folder) REFERENCES public.folder(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: team_library_folder_has_many_sorting team_library_folder_has_many_sorting_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.team_library_folder_has_many_sorting
    ADD CONSTRAINT team_library_folder_has_many_sorting_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: team_library_user_permission team_library_user_permission_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.team_library_user_permission
    ADD CONSTRAINT team_library_user_permission_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: thumb_preview thumb_preview_id_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.thumb_preview
    ADD CONSTRAINT thumb_preview_id_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: thumbnail thumbnail_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.thumbnail
    ADD CONSTRAINT thumbnail_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: thumbnail_version thumbnail_version_composite_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.thumbnail_version
    ADD CONSTRAINT thumbnail_version_composite_unit_fk FOREIGN KEY (id_unit, id_user) REFERENCES public.unit(id, id_user) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: unit unit_folder_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.unit
    ADD CONSTRAINT unit_folder_fk FOREIGN KEY (id_folder) REFERENCES public.folder(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: unit unit_id_geocoding_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.unit
    ADD CONSTRAINT unit_id_geocoding_fk FOREIGN KEY (id_geocoding) REFERENCES public.geocoding(id) MATCH FULL ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: favorite_timeline unit_id_item_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.favorite_timeline
    ADD CONSTRAINT unit_id_item_id_fk FOREIGN KEY (id_unit, id_item) REFERENCES public.unit(id, id_item) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: favorite_timeline unit_id_item_type_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.favorite_timeline
    ADD CONSTRAINT unit_id_item_type_fk FOREIGN KEY (id_unit, item_type) REFERENCES public.unit(id, item_type) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: favorite_timeline unit_id_takentime_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.favorite_timeline
    ADD CONSTRAINT unit_id_takentime_fk FOREIGN KEY (id_unit, takentime) REFERENCES public.unit(id, takentime) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: unit unit_user_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.unit
    ADD CONSTRAINT unit_user_id_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: user_flag user_flag_id_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.user_flag
    ADD CONSTRAINT user_flag_id_user_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: concept_album_additional user_info_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.concept_album_additional
    ADD CONSTRAINT user_info_fk FOREIGN KEY (id_user) REFERENCES public.user_info(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: video_additional video_additional_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.video_additional
    ADD CONSTRAINT video_additional_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: video_convert video_convert_unit_fk; Type: FK CONSTRAINT; Schema: public; Owner: SynologyPhotos
--

ALTER TABLE ONLY public.video_convert
    ADD CONSTRAINT video_convert_unit_fk FOREIGN KEY (id_unit) REFERENCES public.unit(id) MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

