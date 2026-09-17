"""Cross-paradigm benchmark runner: Relational vs Data Warehouse vs Graph.

Executes semantically equivalent queries across:
  1. PostgreSQL (openalex schema - 3NF Relational OLTP)
  2. PostgreSQL (warehouse schema - Star Schema OLAP)
  3. Neo4j (Labeled Property Graph - Cypher)

Follows the evaluation methodology in docs/scope.md:
  - 1 warm-up execution
  - N timed repetitions with warm cache
  - Records median, min, max wall-clock time (ms) and row cardinality
"""

from __future__ import annotations

import argparse
import os
import statistics
import time
from typing import Any, Dict, List, Optional, Tuple

from dotenv import load_dotenv
import psycopg
from neo4j import GraphDatabase

load_dotenv()


def get_postgres_conn_str(override: Optional[str] = None) -> str:
    if override:
        return override
    if "DATABASE_URL" in os.environ:
        return os.environ["DATABASE_URL"]
    user = os.getenv("POSTGRES_USER", "openalex_app")
    password = os.getenv("POSTGRES_PASSWORD", "openalex")
    host = os.getenv("POSTGRES_HOST", "localhost")
    port = os.getenv("POSTGRES_PORT", "5432")
    db = os.getenv("POSTGRES_DB", "openalex")
    return f"postgresql://{user}:{password}@{host}:{port}/{db}"


def get_neo4j_driver(
    uri: Optional[str] = None,
    user: Optional[str] = None,
    password: Optional[str] = None,
):
    neo_uri = uri or os.getenv("NEO4J_URI", "bolt://localhost:7687")
    neo_user = user or os.getenv("NEO4J_USER", "neo4j")
    neo_pwd = password or os.getenv("NEO4J_PASSWORD")

    # Match parsing logic used in scripts/load/load_neo4j.py
    if not neo_pwd and os.getenv("NEO4J_AUTH") and "/" in os.getenv("NEO4J_AUTH", ""):
        parts = os.getenv("NEO4J_AUTH", "").split("/", 1)
        neo_user = parts[0]
        neo_pwd = parts[1]

    if not neo_pwd:
        neo_pwd = "openalex_graph"

    return GraphDatabase.driver(neo_uri, auth=(neo_user, neo_pwd))


# ==============================================================================
# WORKLOAD DEFINITIONS
# ==============================================================================

WORKLOADS = {
        "Q1": {
            "title": "LLM/Generative-AI Evolution by Year, Work Type, and Source",
            "description": "Roll-up and drill-down of LLM/Generative-AI works by publication year, work type, and source with work counts and citation statistics",
            "relational": """
                SET search_path TO openalex, public;
                SELECT
                    publication_year,
                    work_type,
                    COUNT(*) AS work_count,
                    ROUND(AVG(cited_by_count), 2) AS avg_cited_by_count,
                    percentile_cont(0.5) WITHIN GROUP (ORDER BY cited_by_count) AS median_cited_by_count
                FROM works
                GROUP BY publication_year, work_type
                ORDER BY publication_year, work_type;  
            """,
            
        "warehouse": """
                SET search_path TO warehouse, public;
                SELECT
                    f.publication_year,
                    wt.work_type,
                    SUM(f.publication_count) AS work_count,
                    ROUND(AVG(f.cited_by_count), 2) AS avg_cited_by_count,
                    percentile_cont(0.5) WITHIN GROUP (ORDER BY f.cited_by_count) AS median_cited_by_count
                FROM fact_work f
                JOIN dim_work_type wt ON wt.work_type_key = f.work_type_key
                GROUP BY f.publication_year, wt.work_type
                ORDER BY f.publication_year, wt.work_type; 
        """,

        "graph": """
                MATCH (w:Work)
                RETURN w.publication_year AS publication_year,
                       w.work_type AS work_type,
                       count(w) AS work_count,
                       avg(toFloat(w.cited_by_count)) AS mean_citations,
                       percentileCont(toFloat(w.cited_by_count), 0.5) AS median_citations
                ORDER BY publication_year, work_type;


        """
},
    "Q2A": {
        "title": "Top 20 Authors Productivity (Aggregation)",
        "description": "Group-by over author-work relationships with citation sum and count",
        "relational": """
            SELECT a.author_id, a.display_name,
                   COUNT(DISTINCT au.work_id) AS work_count,
                   SUM(w.cited_by_count) AS summed_work_citations
            FROM authors a
            JOIN authorships au ON au.author_id = a.author_id
            JOIN works w ON w.work_id = au.work_id
            GROUP BY a.author_id, a.display_name
            ORDER BY work_count DESC, summed_work_citations DESC, a.author_id
            LIMIT 20;
        """,
        "warehouse": """
            SELECT a.author_id, a.display_name,
                   SUM(f.publication_count) AS work_count,
                   SUM(f.cited_by_count) AS summed_work_citations
            FROM fact_work f
            JOIN bridge_work_author bwa ON bwa.work_key = f.work_key
            JOIN dim_author a ON a.author_key = bwa.author_key
            GROUP BY a.author_id, a.display_name
            ORDER BY work_count DESC, summed_work_citations DESC, a.author_id
            LIMIT 20;
        """,
        "graph": """
            MATCH (a:Author)-[:AUTHORED]->(w:Work)
            WITH a, collect(DISTINCT w) AS works
            RETURN a.id AS author_id,
                   a.display_name AS author_name,
                   size(works) AS work_count,
                   reduce(total = 0, w IN works | total + w.cited_by_count) AS summed_work_citations
            ORDER BY work_count DESC, summed_work_citations DESC, author_id
            LIMIT 20;
        """,
    },
    "Q2B": {
        "title": "Top 20 Institutions (Contextual Affiliations)",
        "description": "Distinct work count and citations per institution",
        "relational": """
            WITH institution_works AS (
                SELECT DISTINCT institution_id, work_id FROM affiliations
            )
            SELECT i.institution_id, i.display_name, COUNT(*) AS work_count, SUM(w.cited_by_count) AS citations
            FROM institution_works iw
            JOIN institutions i ON i.institution_id = iw.institution_id
            JOIN works w ON w.work_id = iw.work_id
            GROUP BY i.institution_id, i.display_name
            ORDER BY work_count DESC, citations DESC, i.institution_id
            LIMIT 20;
        """,
        "warehouse": """
            SELECT i.institution_id, i.display_name,
                   SUM(f.publication_count) AS work_count, SUM(f.cited_by_count) AS citations
            FROM fact_work f
            JOIN bridge_work_institution bwi ON bwi.work_key = f.work_key
            JOIN dim_institution i ON i.institution_key = bwi.institution_key
            GROUP BY i.institution_id, i.display_name
            ORDER BY work_count DESC, citations DESC, i.institution_id
            LIMIT 20;
        """,
        "graph": """
            MATCH (a:Author)-[af:AFFILIATED_WITH]->(i:Institution)
            MATCH (a)-[:AUTHORED]->(w:Work {id: af.work_id})
            WITH i, collect(DISTINCT w) AS works
            RETURN i.id AS institution_id,
                   i.display_name AS institution_name,
                   size(works) AS work_count,
                   reduce(total = 0, w IN works | total + w.cited_by_count) AS citations
            ORDER BY work_count DESC, citations DESC, institution_id
            LIMIT 20;
        """,
    },
    "Q3": {
        "title": "Topic-Field Roll-Up in 2020 (Dimensional Slicing)",
        "description": "Aggregation up the topic hierarchy filtered by publication year",
        "relational": """
            SELECT
                t.field_name,
                COUNT(DISTINCT wt.work_id) AS work_count,
                ROUND(AVG(w.cited_by_count), 2) AS avg_citations
            FROM work_topics wt
            JOIN topics t ON t.topic_id = wt.topic_id
            JOIN works w ON w.work_id = wt.work_id
            WHERE w.publication_year = 2020
            GROUP BY t.field_name
            ORDER BY work_count DESC;
        """,
        "warehouse": """
            SELECT
                t.field_name,
                COUNT(DISTINCT f.work_key) AS work_count,
                ROUND(AVG(f.cited_by_count), 2) AS avg_citations
            FROM fact_work f
            JOIN bridge_work_topic bwt ON bwt.work_key = f.work_key
            JOIN dim_topic t ON t.topic_key = bwt.topic_key
            WHERE f.publication_year = 2020
            GROUP BY t.field_name
            ORDER BY work_count DESC;
        """,
        "graph": """
            MATCH (w:Work {publication_year: 2020})-[:HAS_TOPIC]->(t:Topic)
            WITH DISTINCT w, t.field_name AS field_name
            RETURN field_name,
                   count(w) AS work_count,
                   round(avg(w.cited_by_count), 2) AS avg_citations
            ORDER BY work_count DESC;
        """,
    },
    "Q4": {
        "title": "Inter-Institution Collaboration (Diamond Join)",
        "description": "Pairs of institutions collaborating on works in year 2020",
        "relational": """
            WITH work_institutions AS (
                SELECT DISTINCT work_id, institution_id
                FROM affiliations
            ), institution_pairs AS (
                SELECT
                    left_side.work_id,
                    left_side.institution_id AS institution_1_id,
                    right_side.institution_id AS institution_2_id
                FROM work_institutions left_side
                JOIN work_institutions right_side
                  ON right_side.work_id = left_side.work_id
                 AND right_side.institution_id > left_side.institution_id
            )
            SELECT
                i1.display_name AS institution_1,
                i2.display_name AS institution_2,
                COUNT(*) AS collaborative_work_count,
                SUM(w.cited_by_count) AS summed_work_citations
            FROM institution_pairs p
            JOIN works w ON w.work_id = p.work_id
            JOIN institutions i1 ON i1.institution_id = p.institution_1_id
            JOIN institutions i2 ON i2.institution_id = p.institution_2_id
            WHERE w.publication_year = 2020
            GROUP BY i1.display_name, i2.display_name
            ORDER BY collaborative_work_count DESC, summed_work_citations DESC
            LIMIT 30;
        """,
        "warehouse": """
            WITH institution_pairs AS (
                SELECT
                    left_side.work_key,
                    left_side.institution_key AS institution_1_key,
                    right_side.institution_key AS institution_2_key
                FROM bridge_work_institution left_side
                JOIN bridge_work_institution right_side
                  ON right_side.work_key = left_side.work_key
                 AND right_side.institution_key > left_side.institution_key
            )
            SELECT
                i1.display_name AS institution_1,
                i2.display_name AS institution_2,
                SUM(f.publication_count) AS collaborative_work_count,
                SUM(f.cited_by_count) AS summed_work_citations
            FROM institution_pairs p
            JOIN fact_work f ON f.work_key = p.work_key
            JOIN dim_institution i1 ON i1.institution_key = p.institution_1_key
            JOIN dim_institution i2 ON i2.institution_key = p.institution_2_key
            WHERE f.publication_year = 2020
            GROUP BY i1.display_name, i2.display_name
            ORDER BY collaborative_work_count DESC, summed_work_citations DESC
            LIMIT 30;
        """,
        "graph": """
            MATCH (a1:Author)-[af1:AFFILIATED_WITH]->(i1:Institution)
            MATCH (a1)-[:AUTHORED]->(w:Work {id: af1.work_id, publication_year: 2020})
            MATCH (a2:Author)-[af2:AFFILIATED_WITH]->(i2:Institution)
            MATCH (a2)-[:AUTHORED]->(w)
            WHERE i1.id < i2.id
            WITH i1, i2, collect(DISTINCT w) AS works
            RETURN i1.display_name AS institution_1,
                   i2.display_name AS institution_2,
                   size(works) AS collaborative_work_count,
                   reduce(total = 0, w IN works | total + w.cited_by_count) AS summed_work_citations
            ORDER BY collaborative_work_count DESC, summed_work_citations DESC
            LIMIT 30;
        """,
    },
    "Q5": {
        "title": "Directed Citation Paths 2–4 Hops (Path Traversal)",
        "description": "Multi-hop reachability along citation edges",
        "relational": """
            WITH RECURSIVE citation_paths AS (
                SELECT
                    c.citing_work_id AS start_work_id,
                    c.cited_work_id AS current_work_id,
                    ARRAY[c.citing_work_id, c.cited_work_id]::TEXT[] AS path,
                    1 AS hops
                FROM citations c
                UNION ALL
                SELECT
                    p.start_work_id,
                    c.cited_work_id,
                    p.path || c.cited_work_id,
                    p.hops + 1
                FROM citation_paths p
                JOIN citations c ON c.citing_work_id = p.current_work_id
                WHERE p.hops < 4
                  AND NOT c.cited_work_id = ANY (p.path)
            )
            SELECT hops, COUNT(*) AS path_count
            FROM citation_paths
            WHERE hops BETWEEN 2 AND 4
            GROUP BY hops
            ORDER BY hops;
        """,
        "warehouse": """
            WITH RECURSIVE citation_paths AS (
                SELECT
                    c.citing_work_key AS start_work_key,
                    c.cited_work_key AS current_work_key,
                    ARRAY[c.citing_work_key, c.cited_work_key]::BIGINT[] AS path,
                    1 AS hops
                FROM bridge_work_citation c
                UNION ALL
                SELECT
                    p.start_work_key,
                    c.cited_work_key,
                    p.path || c.cited_work_key,
                    p.hops + 1
                FROM citation_paths p
                JOIN bridge_work_citation c ON c.citing_work_key = p.current_work_key
                WHERE p.hops < 4
                  AND NOT c.cited_work_key = ANY (p.path)
            )
            SELECT hops, COUNT(*) AS path_count
            FROM citation_paths
            WHERE hops BETWEEN 2 AND 4
            GROUP BY hops
            ORDER BY hops;
        """,
        "graph": """
            MATCH p = (start:Work)-[:CITES*2..4]->(target:Work)
            WHERE reduce(seen = [], n IN nodes(p) | 
                    CASE WHEN n IN seen THEN seen ELSE seen + n END
                  ) = nodes(p)
            RETURN length(p) AS hops, count(p) AS path_count
            ORDER BY hops;
        """,
    },
    "Q6": {
        "title": "Co-Authorship Degree (Two-Hop Bipartite Expansion)",
        "description": "Author node degree over shared work co-authorship",
        "relational": """
            WITH coauthor_edges AS (
                SELECT DISTINCT
                    LEAST(a1.author_id, a2.author_id) AS author_1_id,
                    GREATEST(a1.author_id, a2.author_id) AS author_2_id
                FROM authorships a1
                JOIN authorships a2
                  ON a1.work_id = a2.work_id
                 AND a1.author_id < a2.author_id
            ), author_degree AS (
                SELECT author_1_id AS author_id, COUNT(*) AS degree FROM coauthor_edges GROUP BY author_1_id
                UNION ALL
                SELECT author_2_id AS author_id, COUNT(*) AS degree FROM coauthor_edges GROUP BY author_2_id
            )
            SELECT a.author_id, a.display_name, SUM(d.degree) AS coauthor_degree
            FROM author_degree d
            JOIN authors a ON a.author_id = d.author_id
            GROUP BY a.author_id, a.display_name
            ORDER BY coauthor_degree DESC, a.author_id
            LIMIT 20;
        """,
        "warehouse": """
            WITH coauthor_edges AS (
                SELECT DISTINCT
                    LEAST(left_side.author_key, right_side.author_key) AS author_1_key,
                    GREATEST(left_side.author_key, right_side.author_key) AS author_2_key
                FROM bridge_work_author left_side
                JOIN bridge_work_author right_side
                  ON right_side.work_key = left_side.work_key
                 AND right_side.author_key > left_side.author_key
            ), author_degree AS (
                SELECT author_1_key AS author_key, COUNT(*) AS degree FROM coauthor_edges GROUP BY author_1_key
                UNION ALL
                SELECT author_2_key AS author_key, COUNT(*) AS degree FROM coauthor_edges GROUP BY author_2_key
            )
            SELECT a.author_id, a.display_name, SUM(d.degree) AS coauthor_degree
            FROM author_degree d
            JOIN dim_author a ON a.author_key = d.author_key
            GROUP BY a.author_id, a.display_name
            ORDER BY coauthor_degree DESC, a.author_id
            LIMIT 20;
        """,
        "graph": """
            MATCH (a1:Author)-[:AUTHORED]->(w:Work)<-[:AUTHORED]-(a2:Author)
            WHERE a1 <> a2
            WITH a1, collect(DISTINCT a2) AS coauthors
            RETURN a1.id AS author_id,
                   a1.display_name AS author_name,
                   size(coauthors) AS coauthor_degree
            ORDER BY coauthor_degree DESC, author_id
            LIMIT 20;
        """,
    },
}


def benchmark_sql(
    conn_str: str,
    schema: str,
    query_text: str,
    repetitions: int,
) -> Tuple[Optional[List[float]], Optional[int], Optional[str]]:
    """Executes search_path setup, 1 warm-up, and repetitions timed executions."""
    try:
        with psycopg.connect(conn_str) as conn:
            with conn.cursor() as cur:
                # Set schema context first
                cur.execute(f"SET search_path TO {schema}, public;")

                # Warm-up run
                cur.execute(query_text)
                rows = cur.fetchall()
                row_count = len(rows)

                # Timed repetitions
                timings: List[float] = []
                for _ in range(repetitions):
                    t0 = time.perf_counter()
                    cur.execute(query_text)
                    cur.fetchall()
                    t1 = time.perf_counter()
                    timings.append((t1 - t0) * 1000.0)

        return timings, row_count, None
    except Exception as err:
        return None, None, str(err)


def benchmark_cypher(
    driver,
    query_text: str,
    repetitions: int,
) -> Tuple[Optional[List[float]], Optional[int], Optional[str]]:
    """Executes 1 warm-up and repetitions timed executions in Neo4j."""
    try:
        with driver.session() as session:
            # Warm-up run
            result = session.run(query_text)
            records = list(result)
            row_count = len(records)

            # Timed repetitions
            timings: List[float] = []
            for _ in range(repetitions):
                t0 = time.perf_counter()
                result = session.run(query_text)
                list(result)
                t1 = time.perf_counter()
                timings.append((t1 - t0) * 1000.0)

        return timings, row_count, None
    except Exception as err:
        return None, None, str(err)


def run_benchmarks(
    repetitions: int = 5,
    target_workload: Optional[str] = None,
    pg_conn_str: Optional[str] = None,
    neo_uri: Optional[str] = None,
    neo_user: Optional[str] = None,
    neo_pwd: Optional[str] = None,
):
    pg_conn = get_postgres_conn_str(pg_conn_str)
    neo_driver = None

    try:
        neo_driver = get_neo4j_driver(uri=neo_uri, user=neo_user, password=neo_pwd)
        neo_driver.verify_connectivity()
        print("[INFO] Connected to Neo4j successfully.")
    except Exception as err:
        print(f"[WARN] Could not connect to Neo4j: {err}")
        neo_driver = None

    # Verify PostgreSQL connectivity
    try:
        with psycopg.connect(pg_conn) as test_conn:
            with test_conn.cursor() as test_cur:
                test_cur.execute("SELECT 1;")
        print("[INFO] Connected to PostgreSQL successfully.")
    except Exception as err:
        print(f"[ERROR] Could not connect to PostgreSQL ({pg_conn}): {err}")
        return

    keys = [target_workload] if target_workload and target_workload in WORKLOADS else list(WORKLOADS.keys())
    results: List[Dict[str, Any]] = []

    print(f"\nRunning Cross-Paradigm Benchmarks (Warm-up + {repetitions} repetitions per query)...\n")

    for key in keys:
        spec = WORKLOADS[key]
        print(f"-> Testing {key}: {spec['title']}...")

        # Relational
        rel_times, rel_rows, rel_err = benchmark_sql(pg_conn, "openalex", spec["relational"], repetitions)
        if rel_err:
            print(f"   [Relational Error]: {rel_err}")

        # Warehouse
        wh_times, wh_rows, wh_err = benchmark_sql(pg_conn, "warehouse", spec["warehouse"], repetitions)
        if wh_err:
            print(f"   [Warehouse Error]: {wh_err}")

        # Graph
        if neo_driver:
            graph_times, graph_rows, graph_err = benchmark_cypher(neo_driver, spec["graph"], repetitions)
            if graph_err:
                print(f"   [Graph Error]: {graph_err}")
        else:
            graph_times, graph_rows, graph_err = None, None, "Neo4j not connected"

        res_item = {
            "key": key,
            "title": spec["title"],
            "rel_median": statistics.median(rel_times) if rel_times else None,
            "rel_min": min(rel_times) if rel_times else None,
            "rel_max": max(rel_times) if rel_times else None,
            "rel_rows": rel_rows,
            "wh_median": statistics.median(wh_times) if wh_times else None,
            "wh_min": min(wh_times) if wh_times else None,
            "wh_max": max(wh_times) if wh_times else None,
            "wh_rows": wh_rows,
            "graph_median": statistics.median(graph_times) if graph_times else None,
            "graph_min": min(graph_times) if graph_times else None,
            "graph_max": max(graph_times) if graph_times else None,
            "graph_rows": graph_rows,
        }
        results.append(res_item)

    if neo_driver:
        neo_driver.close()

    # Print summary table
    print("\n" + "=" * 118)
    print(f"{'Workload':<8} | {'Task / Query Description':<32} | {'Relational (ms)':<16} | {'Warehouse (ms)':<16} | {'Graph Neo4j (ms)':<16} | {'Winner':<10}")
    print("=" * 118)

    for r in results:
        rel_str = f"{r['rel_median']:.2f} (±{r['rel_max'] - r['rel_min']:.1f})" if r["rel_median"] is not None else "ERROR"
        wh_str = f"{r['wh_median']:.2f} (±{r['wh_max'] - r['wh_min']:.1f})" if r["wh_median"] is not None else "ERROR"
        g_str = f"{r['graph_median']:.2f} (±{r['graph_max'] - r['graph_min']:.1f})" if r["graph_median"] is not None else ("N/A" if not neo_driver else "ERROR")

        # Determine winner among available timings
        candidates = []
        if r["rel_median"] is not None:
            candidates.append((r["rel_median"], "Relational"))
        if r["wh_median"] is not None:
            candidates.append((r["wh_median"], "Warehouse"))
        if r["graph_median"] is not None:
            candidates.append((r["graph_median"], "Graph"))

        if candidates:
            winner = min(candidates, key=lambda x: x[0])[1]
        else:
            winner = "N/A"

        print(f"{r['key']:<8} | {r['title'][:32]:<32} | {rel_str:<16} | {wh_str:<16} | {g_str:<16} | {winner:<10}")

    print("=" * 118)
    print("Note: Reported figures are median wall-clock execution times in milliseconds (warm cache).")


def main():
    parser = argparse.ArgumentParser(description="Benchmark Relational vs Warehouse vs Graph databases.")
    parser.add_argument("--iterations", "-n", type=int, default=5, help="Number of repetitions per query (default: 5)")
    parser.add_argument("--workload", "-w", type=str, choices=list(WORKLOADS.keys()), help="Run a specific workload (e.g., Q3, Q5)")
    parser.add_argument("--pg-conn", type=str, default=None, help="PostgreSQL connection string override")
    parser.add_argument("--neo4j-uri", type=str, default=None, help="Neo4j bolt URI override")
    parser.add_argument("--neo4j-user", type=str, default=None, help="Neo4j user override")
    parser.add_argument("--neo4j-password", type=str, default=None, help="Neo4j password override")
    args = parser.parse_args()

    run_benchmarks(
        repetitions=args.iterations,
        target_workload=args.workload,
        pg_conn_str=args.pg_conn,
        neo_uri=args.neo4j_uri,
        neo_user=args.neo4j_user,
        neo_pwd=args.neo4j_password,
    )


if __name__ == "__main__":
    main()
