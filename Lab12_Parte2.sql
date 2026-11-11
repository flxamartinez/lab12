-- =====================================================================
-- Parte 0
-- =====================================================================
CREATE TABLE employees (
emp_no int,
birth_date date,
first_name varchar(14),
last_name varchar(16),
gender character(1),
hire_date date,
dept_no varchar(5),
from_date date
);
CREATE TABLE salaries (
emp_no int,
salary int ,
from_date date,
to_date date
);


COPY public.employees
FROM '/tmp/employees.csv'
WITH (FORMAT CSV, HEADER true, DELIMITER ',');

COPY public.salaries
FROM '/tmp/salaries.csv'
WITH (FORMAT CSV, HEADER true, DELIMITER ',');

VACUUM ANALYZE public.employees;
VACUUM ANALYZE public.salaries;
SELECT
    (SELECT COUNT(*) FROM public.employees) AS numero_filas,
    pg_relation_size('public.employees'::regclass) AS tamanio_bytes,
    pg_size_pretty(
        pg_relation_size('public.employees'::regclass)
    ) AS tamanio_legible,
    relpages AS numero_paginas
FROM pg_class
WHERE oid = 'public.employees'::regclass;

SELECT DISTINCT dept_no
FROM employees
ORDER BY dept_no;

EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM employees WHERE dept_no = 'd001';

-- =====================================================================
-- Parte 1
-- =====================================================================

-- P1.3: 
SELECT
    dept_no,
    COUNT(*) AS cantidad_empleados
FROM employees
GROUP BY dept_no
ORDER BY cantidad_empleados DESC;


CREATE TABLE public.employees1 (
    LIKE public.employees
)
PARTITION BY LIST (dept_no);

CREATE TABLE public.employees1_f1
PARTITION OF public.employees1
FOR VALUES IN ('d005', 'd009');

CREATE TABLE public.employees1_f2
PARTITION OF public.employees1
FOR VALUES IN ('d004', 'd001', 'd002');

CREATE TABLE public.employees1_f3
PARTITION OF public.employees1
FOR VALUES IN ('d007', 'd008', 'd006', 'd003');

INSERT INTO public.employees1
SELECT * FROM public.employees;

VACUUM ANALYZE public.employees1_f1;

VACUUM ANALYZE public.employees1_f2;

VACUUM ANALYZE public.employees1_f3;

ANALYZE public.employees1;

SELECT
    tableoid::regclass AS fragmento,
    COUNT(*) AS cantidad_registros
FROM public.employees1
GROUP BY tableoid
ORDER BY fragmento;

-- 1.4
SET max_parallel_workers_per_gather = 0;
SET jit = off;
SET enable_partition_pruning = on;

-- Q1
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM public.employees
WHERE dept_no = 'd001';

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM public.employees1
WHERE dept_no = 'd001';

-- Q2
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM public.employees
WHERE dept_no IN ('d001', 'd005');

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM public.employees1
WHERE dept_no IN ('d001', 'd005');

-- Q3
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM public.employees
WHERE last_name = 'Facello';

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM public.employees1
WHERE last_name = 'Facello';

SET enable_partition_pruning = off;

-- Q4:
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM public.employees
WHERE dept_no = 'd001';

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM public.employees1
WHERE dept_no = 'd001';

SET enable_partition_pruning = on;

-- Q5:
INSERT INTO public.employees1 (
    emp_no, birth_date, first_name, last_name,
    gender, hire_date, dept_no, from_date
)
VALUES (
    -10010, '1990-01-01', 'Prueba', 'Laboratorio',
    'M', '2026-01-01', 'd010', '2026-01-01'
);

CREATE TABLE public.employees1_default
PARTITION OF public.employees1
DEFAULT;

SELECT
    tableoid::regclass AS fragmento,
    emp_no,
    dept_no
FROM public.employees1
WHERE emp_no = -10010
  AND dept_no = 'd010';

-- P1.5:

SET max_parallel_workers_per_gather = 0;
SET jit = off;
SET enable_partition_pruning = on;

CREATE TABLE public.employees1_mal (
    LIKE public.employees
)
PARTITION BY LIST (dept_no);

CREATE TABLE public.mal_grande
PARTITION OF public.employees1_mal
FOR VALUES IN (
    'd005', 'd004', 'd009', 'd001', 'd003', 'd002'
);

CREATE TABLE public.mal_pequeno1
PARTITION OF public.employees1_mal
FOR VALUES IN ('d007');

CREATE TABLE public.mal_pequeno2
PARTITION OF public.employees1_mal
FOR VALUES IN ('d008', 'd006');

INSERT INTO public.employees1_mal
SELECT * FROM public.employees;

VACUUM ANALYZE public.mal_grande;

VACUUM ANALYZE public.mal_pequeno1;

VACUUM ANALYZE public.mal_pequeno2;

SELECT
    tableoid::regclass AS fragmento,
    COUNT(*) AS registros
FROM public.employees1_mal
GROUP BY tableoid
ORDER BY registros DESC;

-- Q1 antes del rebalanceo.
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM public.employees1_mal
WHERE dept_no = 'd001';

BEGIN;

ALTER TABLE public.employees1_mal
DETACH PARTITION public.mal_grande;

CREATE TABLE public.mal_grande_a
PARTITION OF public.employees1_mal
FOR VALUES IN ('d005', 'd001', 'd002');

CREATE TABLE public.mal_grande_b
PARTITION OF public.employees1_mal
FOR VALUES IN ('d004', 'd009', 'd003');

INSERT INTO public.employees1_mal
SELECT * FROM public.mal_grande;

DROP TABLE public.mal_grande;

ALTER TABLE public.employees1_mal
DETACH PARTITION public.mal_pequeno1;

ALTER TABLE public.employees1_mal
DETACH PARTITION public.mal_pequeno2;

CREATE TABLE public.mal_combinado
PARTITION OF public.employees1_mal
FOR VALUES IN ('d007', 'd008', 'd006');

INSERT INTO public.employees1_mal
SELECT * FROM public.mal_pequeno1;

INSERT INTO public.employees1_mal
SELECT * FROM public.mal_pequeno2;

DROP TABLE public.mal_pequeno1;
DROP TABLE public.mal_pequeno2;

COMMIT;

VACUUM ANALYZE public.mal_grande_a;

VACUUM ANALYZE public.mal_grande_b;

VACUUM ANALYZE public.mal_combinado;

ANALYZE public.employees1_mal;

SELECT
    tableoid::regclass AS fragmento,
    COUNT(*) AS registros
FROM public.employees1_mal
GROUP BY tableoid
ORDER BY registros DESC;

-- Q1 después del rebalanceo.
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM public.employees1_mal
WHERE dept_no = 'd001';

-- Prueba de concurrencia
BEGIN;

ALTER TABLE public.employees1_mal
DETACH PARTITION public.mal_grande_a;

--en otra sesion
SELECT COUNT(*)
FROM public.employees1_mal;

ROLLBACK;

-- =====================================================================
-- Parte 2
-- =====================================================================

-- ---------------------------------------------------------------------
-- 3.3 Implementar
-- ---------------------------------------------------------------------

-- 3.3.1 Distribución de contrataciones por año
SELECT anio, n,
round(100.0 * n / sum(n) OVER (), 2) AS pct,
sum(n) OVER (ORDER BY anio) AS acumulado,
round(100.0 * sum(n) OVER (ORDER BY anio) / sum(n) OVER (), 2) AS pct_acumulado
FROM (SELECT date_part('year', hire_date)::int AS anio, count(*) AS n
FROM employees GROUP BY 1) t
ORDER BY anio;

-- 3.3.2 Vector de particionamiento
WITH por_anio AS (
SELECT date_part('year', hire_date)::int AS anio, count(*) AS n
FROM employees GROUP BY 1
), total AS (
SELECT sum(n) AS n_total FROM por_anio
), candidatos AS (
SELECT a.anio AS a, b.anio AS b
FROM por_anio a JOIN por_anio b ON b.anio > a.anio
WHERE a.anio > (SELECT min(anio) FROM por_anio)
), fragmentos AS (
SELECT c.a, c.b,
sum(p.n) FILTER (WHERE p.anio < c.a) AS f1,
sum(p.n) FILTER (WHERE p.anio >= c.a AND p.anio < c.b) AS f2,
sum(p.n) FILTER (WHERE p.anio >= c.b) AS f3
FROM candidatos c CROSS JOIN por_anio p
GROUP BY c.a, c.b
)
SELECT format('[%s, %s]', a, b) AS vector, f1, f2, f3,
round(greatest(f1, f2, f3) / (t.n_total / 3.0), 3) AS coef_desbalance
FROM fragmentos, total t
ORDER BY coef_desbalance
LIMIT 5;

SELECT vector,
count(*) FILTER (WHERE anio < a) AS f1,
count(*) FILTER (WHERE anio >= a AND anio < b) AS f2,
count(*) FILTER (WHERE anio >= b) AS f3,
round(greatest(count(*) FILTER (WHERE anio < a),
count(*) FILTER (WHERE anio >= a AND anio < b),
count(*) FILTER (WHERE anio >= b))
/ (count(*) / 3.0), 3) AS coef_desbalance
FROM (SELECT date_part('year', hire_date) AS anio FROM employees) e
CROSS JOIN (VALUES ('[1988, 1992] elegido', 1988, 1992),
('[1988, 1994] ejemplo PDF', 1988, 1994)) AS v(vector, a, b)
GROUP BY vector
ORDER BY coef_desbalance;

-- 3.3.3 Cree y Cargue
DROP TABLE IF EXISTS employees2 CASCADE;

CREATE TABLE employees2 (
emp_no int,
birth_date date,
first_name varchar(14),
last_name varchar(16),
gender character(1),
hire_date date,
dept_no varchar(5),
from_date date
) PARTITION BY RANGE (date_part('year', hire_date));

CREATE TABLE employees2_p1 PARTITION OF employees2 FOR VALUES FROM (MINVALUE) TO (1988);
CREATE TABLE employees2_p2 PARTITION OF employees2 FOR VALUES FROM (1988) TO (1992);
CREATE TABLE employees2_p3 PARTITION OF employees2 FOR VALUES FROM (1992) TO (MAXVALUE);

INSERT INTO employees2 SELECT * FROM employees;

VACUUM ANALYZE employees2;

DROP TABLE IF EXISTS employees2b CASCADE;

CREATE TABLE employees2b (
emp_no int,
birth_date date,
first_name varchar(14),
last_name varchar(16),
gender character(1),
hire_date date,
dept_no varchar(5),
from_date date
) PARTITION BY RANGE (hire_date);

CREATE TABLE employees2b_p1 PARTITION OF employees2b FOR VALUES FROM (MINVALUE) TO ('1988-01-01');
CREATE TABLE employees2b_p2 PARTITION OF employees2b FOR VALUES FROM ('1988-01-01') TO ('1992-01-01');
CREATE TABLE employees2b_p3 PARTITION OF employees2b FOR VALUES FROM ('1992-01-01') TO (MAXVALUE);

INSERT INTO employees2b SELECT * FROM employees;

VACUUM ANALYZE employees2b;

-- 3.3.4 Verificación de la carga
SELECT 'employees2' AS tabla, tableoid::regclass AS fragmento, count(*) AS filas
FROM employees2 GROUP BY 2
UNION ALL
SELECT 'employees2b', tableoid::regclass, count(*)
FROM employees2b GROUP BY 2
ORDER BY 1, 2;

-- 3.3.5 Cómo guardó PostgreSQL cada clave
SELECT p.relname AS tabla,
pg_get_partkeydef(p.oid) AS clave_de_particion,
c.relname AS fragmento,
pg_get_expr(c.relpartbound, c.oid) AS limites
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
JOIN pg_class p ON p.oid = i.inhparent
WHERE p.relname IN ('employees2', 'employees2b')
ORDER BY 1, 3;

-- ---------------------------------------------------------------------
-- 3.4 Experimentar
-- ---------------------------------------------------------------------

SET max_parallel_workers_per_gather = 0;
SET jit = off;
SET enable_partition_pruning = on;

CREATE OR REPLACE FUNCTION medir(consulta text, repeticiones int DEFAULT 5)
RETURNS TABLE (
planning_ms numeric,
execution_ms numeric,
shared_hit numeric,
shared_read numeric,
particiones int,
nodos_acceso text
)
LANGUAGE plpgsql AS $f$
DECLARE
plan jsonb;
t_plan float8[] := '{}';
t_exec float8[] := '{}';
b_hit float8[] := '{}';
b_read float8[] := '{}';
BEGIN
FOR i IN 1..repeticiones LOOP
EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || consulta INTO plan;
IF i > 1 THEN
t_plan := t_plan || (plan->0->>'Planning Time')::float8;
t_exec := t_exec || (plan->0->>'Execution Time')::float8;
b_hit := b_hit || (plan->0->'Plan'->>'Shared Hit Blocks')::float8;
b_read := b_read || (plan->0->'Plan'->>'Shared Read Blocks')::float8;
END IF;
END LOOP;

RETURN QUERY SELECT
(SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY x)::numeric, 3) FROM unnest(t_plan) x),
(SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY x)::numeric, 3) FROM unnest(t_exec) x),
(SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY x)::numeric, 1) FROM unnest(b_hit) x),
(SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY x)::numeric, 1) FROM unnest(b_read) x),
(SELECT count(DISTINCT r)::int
FROM jsonb_path_query(plan, 'strict $.**."Relation Name"') r),
(SELECT string_agg(DISTINCT n #>> '{}', ', ')
FROM jsonb_path_query(plan, 'strict $.**."Node Type"') n
WHERE n #>> '{}' LIKE '%Scan%');
END
$f$;

SELECT * FROM medir($$SELECT * FROM employees WHERE dept_no = 'd005'$$);

-- 3.4.1 Experimento Q1
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM employees2 WHERE date_part('year', hire_date) = 1990;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM employees2b WHERE date_part('year', hire_date) = 1990;

SELECT 'employees' AS tabla, * FROM medir($$SELECT * FROM employees WHERE date_part('year', hire_date) = 1990$$)
UNION ALL
SELECT 'employees2', * FROM medir($$SELECT * FROM employees2 WHERE date_part('year', hire_date) = 1990$$)
UNION ALL
SELECT 'employees2b', * FROM medir($$SELECT * FROM employees2b WHERE date_part('year', hire_date) = 1990$$);

-- 3.4.2 Experimento Q2
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM employees2 WHERE hire_date BETWEEN '1990-01-01' AND '1990-12-31';

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM employees2b WHERE hire_date BETWEEN '1990-01-01' AND '1990-12-31';

SELECT 'employees' AS tabla, * FROM medir($$SELECT * FROM employees WHERE hire_date BETWEEN '1990-01-01' AND '1990-12-31'$$)
UNION ALL
SELECT 'employees2', * FROM medir($$SELECT * FROM employees2 WHERE hire_date BETWEEN '1990-01-01' AND '1990-12-31'$$)
UNION ALL
SELECT 'employees2b', * FROM medir($$SELECT * FROM employees2b WHERE hire_date BETWEEN '1990-01-01' AND '1990-12-31'$$);

-- 3.4.3 Experimento Q3
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM employees2 WHERE extract(year FROM hire_date) = 1990;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM employees2b WHERE extract(year FROM hire_date) = 1990;

SELECT 'employees' AS tabla, * FROM medir($$SELECT * FROM employees WHERE extract(year FROM hire_date) = 1990$$)
UNION ALL
SELECT 'employees2', * FROM medir($$SELECT * FROM employees2 WHERE extract(year FROM hire_date) = 1990$$)
UNION ALL
SELECT 'employees2b', * FROM medir($$SELECT * FROM employees2b WHERE extract(year FROM hire_date) = 1990$$);

-- 3.4.4 Experimento B: índice vs. fragmentación
DROP INDEX IF EXISTS idx_emp_hire;
DROP INDEX IF EXISTS idx_emp2b_hire;

-- Sin índice
SELECT q.rango, q.tabla, m.execution_ms, m.shared_hit, m.particiones, m.nodos_acceso
FROM (VALUES
('1 mes', 'employees', $$SELECT * FROM employees WHERE hire_date BETWEEN '1990-06-01' AND '1990-06-30'$$),
('1 mes', 'employees2b', $$SELECT * FROM employees2b WHERE hire_date BETWEEN '1990-06-01' AND '1990-06-30'$$),
('1 año', 'employees', $$SELECT * FROM employees WHERE hire_date BETWEEN '1990-01-01' AND '1990-12-31'$$),
('1 año', 'employees2b', $$SELECT * FROM employees2b WHERE hire_date BETWEEN '1990-01-01' AND '1990-12-31'$$),
('5 años', 'employees', $$SELECT * FROM employees WHERE hire_date BETWEEN '1990-01-01' AND '1994-12-31'$$),
('5 años', 'employees2b', $$SELECT * FROM employees2b WHERE hire_date BETWEEN '1990-01-01' AND '1994-12-31'$$),
('Todo', 'employees', $$SELECT * FROM employees WHERE hire_date BETWEEN '1985-01-01' AND '2000-12-31'$$),
('Todo', 'employees2b', $$SELECT * FROM employees2b WHERE hire_date BETWEEN '1985-01-01' AND '2000-12-31'$$)
) AS q(rango, tabla, consulta)
CROSS JOIN LATERAL medir(q.consulta) m;

-- Creación de índices
CREATE INDEX idx_emp_hire ON employees (hire_date);
CREATE INDEX idx_emp2b_hire ON employees2b (hire_date);
ANALYZE employees;
ANALYZE employees2b;

SELECT tablename, indexname
FROM pg_indexes
WHERE tablename IN ('employees', 'employees2b', 'employees2b_p1', 'employees2b_p2', 'employees2b_p3')
ORDER BY 1;

-- Con índice
SELECT q.rango, q.tabla, m.execution_ms, m.shared_hit, m.particiones, m.nodos_acceso
FROM (VALUES
('1 mes', 'employees', $$SELECT * FROM employees WHERE hire_date BETWEEN '1990-06-01' AND '1990-06-30'$$),
('1 mes', 'employees2b', $$SELECT * FROM employees2b WHERE hire_date BETWEEN '1990-06-01' AND '1990-06-30'$$),
('1 año', 'employees', $$SELECT * FROM employees WHERE hire_date BETWEEN '1990-01-01' AND '1990-12-31'$$),
('1 año', 'employees2b', $$SELECT * FROM employees2b WHERE hire_date BETWEEN '1990-01-01' AND '1990-12-31'$$),
('5 años', 'employees', $$SELECT * FROM employees WHERE hire_date BETWEEN '1990-01-01' AND '1994-12-31'$$),
('5 años', 'employees2b', $$SELECT * FROM employees2b WHERE hire_date BETWEEN '1990-01-01' AND '1994-12-31'$$),
('Todo', 'employees', $$SELECT * FROM employees WHERE hire_date BETWEEN '1985-01-01' AND '2000-12-31'$$),
('Todo', 'employees2b', $$SELECT * FROM employees2b WHERE hire_date BETWEEN '1985-01-01' AND '2000-12-31'$$)
) AS q(rango, tabla, consulta)
CROSS JOIN LATERAL medir(q.consulta) m;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM employees2b WHERE hire_date BETWEEN '1990-06-01' AND '1990-06-30';

-- Experimento C: número de fragmentos
DROP INDEX IF EXISTS idx_emp2b_hire;

DROP TABLE IF EXISTS employees2c CASCADE;

CREATE TABLE employees2c (
emp_no int,
birth_date date,
first_name varchar(14),
last_name varchar(16),
gender character(1),
hire_date date,
dept_no varchar(5),
from_date date
) PARTITION BY RANGE (hire_date);

DO $$
DECLARE
d date;
d_max date;
BEGIN
SELECT date_trunc('month', min(hire_date))::date, date_trunc('month', max(hire_date))::date
INTO d, d_max FROM employees;
WHILE d <= d_max LOOP
EXECUTE format('CREATE TABLE %I PARTITION OF employees2c FOR VALUES FROM (%L) TO (%L)',
'employees2c_' || to_char(d, 'YYYY_MM'), d, (d + interval '1 month')::date);
d := (d + interval '1 month')::date;
END LOOP;
END
$$;

INSERT INTO employees2c SELECT * FROM employees;

VACUUM ANALYZE employees2c;

SELECT count(*) AS n_fragmentos FROM pg_inherits WHERE inhparent = 'employees2c'::regclass;

SELECT q.consulta_id, q.tabla, m.planning_ms, m.execution_ms, m.shared_hit, m.particiones
FROM (VALUES
('1 mes', 'employees2b (3)', $$SELECT * FROM employees2b WHERE hire_date BETWEEN '1990-06-01' AND '1990-06-30'$$),
('1 mes', 'employees2c (N)', $$SELECT * FROM employees2c WHERE hire_date BETWEEN '1990-06-01' AND '1990-06-30'$$),
('Facello', 'employees2b (3)', $$SELECT * FROM employees2b WHERE last_name = 'Facello'$$),
('Facello', 'employees2c (N)', $$SELECT * FROM employees2c WHERE last_name = 'Facello'$$)
) AS q(consulta_id, tabla, consulta)
CROSS JOIN LATERAL medir(q.consulta) m;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM employees2c WHERE hire_date BETWEEN '1990-06-01' AND '1990-06-30';