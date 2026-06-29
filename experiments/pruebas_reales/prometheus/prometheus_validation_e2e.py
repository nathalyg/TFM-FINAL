#!/usr/bin/env python3
"""
Valida tiempo de recuperacion end-to-end (reloj) contra Prometheus.

Idea:
- Para cada corrida del CSV, toma t_inicio_iso como inicio del evento.
- Busca el primer instante en que el deployment vuelve a estado deseado
  (replicas disponibles >= replicas deseadas) dentro de una ventana.
- Compara ese tiempo Prometheus contra la duracion del script.

CSV de entrada (columnas minimas):
- run_id
- t_inicio_iso
- t_fin_iso
- una columna de duracion (ej: spec_recovery_s, rto_s, c1_degraded_s, c2_rollback_s)
"""

import argparse
import csv
from typing import Optional

import pandas as pd
import requests


DEFAULT_READY_QUERY = (
    'sum(kube_deployment_status_replicas_available{deployment="nginx-demo",namespace="tfm-app"})'
)
DEFAULT_EXPECTED_QUERY = (
    'sum(kube_deployment_spec_replicas{deployment="nginx-demo",namespace="tfm-app"})'
)


def iso_to_unix_seconds(iso_value: str) -> Optional[int]:
    ts = pd.to_datetime(iso_value, utc=True, errors="coerce")
    if pd.isna(ts):
        return None
    return int(ts.timestamp())


def query_range_single_series(
    prom_base_url: str,
    query_expr: str,
    start_s: int,
    end_s: int,
    step: str,
    timeout_s: int = 20,
) -> list[tuple[int, float]]:
    url = f"{prom_base_url.rstrip('/')}/api/v1/query_range"
    params = {
        "query": query_expr,
        "start": start_s,
        "end": end_s,
        "step": step,
    }

    resp = requests.get(url, params=params, timeout=timeout_s)
    resp.raise_for_status()
    payload = resp.json()

    if payload.get("status") != "success":
        return []

    results = payload.get("data", {}).get("result", [])
    if not results:
        return []

    values = results[0].get("values", [])
    out: list[tuple[int, float]] = []
    for item in values:
        try:
            ts = int(float(item[0]))
            value = float(item[1])
        except (ValueError, TypeError, IndexError):
            continue
        out.append((ts, value))
    return out


def resolve_column(df: pd.DataFrame, preferred: str, aliases: list[str]) -> Optional[str]:
    if preferred in df.columns:
        return preferred
    for alias in aliases:
        if alias in df.columns:
            return alias
    return None


def resolve_duration_column(df: pd.DataFrame, preferred: Optional[str] = None) -> Optional[str]:
    if preferred and preferred in df.columns:
        return preferred

    candidates = [
        "rto_s",
        "spec_recovery_s",
        "c2_rollback_s",
        "c1_degraded_s",
        "rto_segundos",
        "rto_script_s",
        "duracion_script_s",
    ]
    for candidate in candidates:
        if candidate in df.columns:
            return candidate
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description="Validacion end-to-end (reloj) script vs Prometheus")
    parser.add_argument("--input-csv", required=True, help="CSV de entrada con tiempos por corrida")
    parser.add_argument("--prom-url", default="http://localhost:9090", help="URL base de Prometheus")
    parser.add_argument("--ready-query", default=DEFAULT_READY_QUERY, help="PromQL de replicas disponibles")
    parser.add_argument(
        "--expected-query",
        default=DEFAULT_EXPECTED_QUERY,
        help="PromQL de replicas deseadas (si no devuelve datos, usa --min-ready)",
    )
    parser.add_argument("--step", default="1s", help="Paso para query_range")
    parser.add_argument("--margin", type=float, default=15.0, help="Margen permitido en segundos")
    parser.add_argument("--lookahead", type=int, default=30, help="Segundos extra despues de t_fin_iso")
    parser.add_argument("--min-ready", type=float, default=1.0, help="Umbral minimo de replicas disponibles")
    parser.add_argument(
        "--value-column",
        default=None,
        help="Columna del CSV con la duracion del script a comparar (si no se indica, se infiere)",
    )
    parser.add_argument(
        "--output-csv",
        default="prometheus_validation_e2e.csv",
        help="CSV de salida",
    )
    args = parser.parse_args()

    df = pd.read_csv(args.input_csv)

    run_col = resolve_column(df, "run_id", ["id", "run"])
    t0_col = resolve_column(df, "t_inicio_iso", ["inicio_iso", "start_iso"])
    t1_col = resolve_column(df, "t_fin_iso", ["fin_iso", "end_iso"])
    value_col = resolve_duration_column(df, args.value_column)

    missing = [
        name
        for name, col in [
            ("run_id", run_col),
            ("t_inicio_iso", t0_col),
            ("t_fin_iso", t1_col),
            ("duracion_script", value_col),
        ]
        if col is None
    ]
    if missing:
        raise ValueError(f"Faltan columnas requeridas en CSV: {', '.join(missing)}")

    rows_out = []

    for _, row in df.iterrows():
        run_id = row[run_col]
        t_script = pd.to_numeric(row[value_col], errors="coerce")

        start_s = iso_to_unix_seconds(str(row[t0_col]))
        end_s = iso_to_unix_seconds(str(row[t1_col]))

        t_prom = None
        if start_s is not None and end_s is not None and end_s >= start_s:
            q_start = start_s
            q_end = end_s + max(0, args.lookahead)

            try:
                ready_series = query_range_single_series(
                    prom_base_url=args.prom_url,
                    query_expr=args.ready_query,
                    start_s=q_start,
                    end_s=q_end,
                    step=args.step,
                )
                expected_series = query_range_single_series(
                    prom_base_url=args.prom_url,
                    query_expr=args.expected_query,
                    start_s=q_start,
                    end_s=q_end,
                    step=args.step,
                )
            except requests.RequestException:
                ready_series = []
                expected_series = []

            expected_by_ts = {ts: v for ts, v in expected_series}
            expected_fallback = max((v for _, v in expected_series), default=args.min_ready)

            for ts, ready_val in ready_series:
                if ts < start_s:
                    continue
                expected_val = expected_by_ts.get(ts, expected_fallback)
                threshold = max(args.min_ready, expected_val)
                if ready_val >= threshold:
                    t_prom = float(ts - start_s)
                    break

        delta = None
        within_margin = False
        if pd.notna(t_script) and t_prom is not None:
            delta = float(t_script) - float(t_prom)
            within_margin = abs(delta) <= args.margin

        rows_out.append(
            {
                "run_id": run_id,
                "t_script_s": float(t_script) if pd.notna(t_script) else "",
                "t_prometheus_e2e_s": round(t_prom, 6) if t_prom is not None else "",
                "delta_s": round(delta, 6) if delta is not None else "",
                "dentro_margen_15s": within_margin,
            }
        )

    with open(args.output_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "run_id",
                "t_script_s",
                "t_prometheus_e2e_s",
                "delta_s",
                "dentro_margen_15s",
            ],
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(rows_out)

    total = len(rows_out)
    valid = [r for r in rows_out if isinstance(r["dentro_margen_15s"], bool)]
    within = sum(1 for r in valid if r["dentro_margen_15s"])

    deltas = [float(r["delta_s"]) for r in rows_out if r["delta_s"] != ""]
    delta_prom = sum(deltas) / len(deltas) if deltas else 0.0

    print(f"CSV generado: {args.output_csv}")
    print(f"Filas totales: {total}")
    print(f"Dentro de margen (+/-{args.margin:.1f}s): {within}/{len(valid)}")
    print(f"Delta promedio (script - Prometheus e2e): {delta_prom:.3f}s")


if __name__ == "__main__":
    main()
