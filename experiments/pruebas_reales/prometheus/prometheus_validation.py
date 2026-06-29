#!/usr/bin/env python3
"""
Valida tiempos del script contra Prometheus para la metrica de ArgoCD.

Modo por defecto: delta para A/B, calculando last - first sobre una serie de rango.
Modo first-one: rama separada para C, buscando la primera muestra con valor 1
en la ventana y devolviendo su timestamp relativo al inicio.

Entrada CSV esperada (columnas minimas):
- run_id
- columnas de inicio y fin del intervalo (por defecto t_inicio_iso / t_fin_iso,
    con aliases para los nuevos nombres del escenario C)
- una columna de duracion del script

Salida:
- prometheus_validation.csv con columnas:
    run_id, t_script_s, t_prometheus_s, delta_s, dentro_margen_15s
"""

import argparse
import csv
from typing import Optional

import pandas as pd
import requests


DEFAULT_QUERY = "sum(argocd_app_reconcile_sum)"
DEFAULT_STATE_QUERY_TEMPLATE = 'argocd_app_info{name="{app}", health_status="Degraded"}'
DEFAULT_HEALTHY_STATE_QUERY_TEMPLATE = 'argocd_app_info{name="{app}", health_status="Healthy"}'


def iso_to_unix_seconds(iso_value: str) -> Optional[int]:
    value = str(iso_value).strip()
    if value and value.lstrip("-").isdigit():
        return int(value)

    ts = pd.to_datetime(value, utc=True, errors="coerce")
    if pd.isna(ts):
        return None
    return int(ts.timestamp())


def get_prometheus_range_delta(
    prom_base_url: str,
    query_expr: str,
    start_s: int,
    end_s: int,
    step: str = "15s",
    timeout_s: int = 20,
) -> Optional[float]:
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
        return None

    results = payload.get("data", {}).get("result", [])
    if not results:
        return None

    values = results[0].get("values", [])
    if len(values) < 2:
        return None

    try:
        first = float(values[0][1])
        last = float(values[-1][1])
    except (ValueError, TypeError, IndexError):
        return None

    delta = last - first
    if delta < 0:
        return None
    return delta


def get_prometheus_first_one_timestamp(
    prom_base_url: str,
    query_expr: str,
    start_s: int,
    end_s: int,
    step: str = "1s",
    timeout_s: int = 20,
) -> Optional[float]:
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
        return None

    results = payload.get("data", {}).get("result", [])
    if not results:
        return None

    first_hits: list[int] = []
    for result in results:
        for item in result.get("values", []):
            try:
                ts = int(float(item[0]))
                value = float(item[1])
            except (ValueError, TypeError, IndexError):
                continue
            if value == 1.0:
                first_hits.append(ts)

    if not first_hits:
        return None

    return float(min(first_hits) - start_s)


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
        "tiempo_deteccion_s",
        "tiempo_recuperacion_post_revert_s",
        "recovery_time_observed_s",
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


def infer_first_one_profile(value_column: Optional[str]) -> tuple[str, str]:
    normalized = (value_column or "").strip().lower()

    recovery_tokens = ("recuperacion", "recovery", "post_revert", "restoration")
    detection_tokens = ("deteccion", "degraded", "degradation")

    if any(token in normalized for token in recovery_tokens):
        return "t3", "healthy"
    if any(token in normalized for token in detection_tokens):
        return "t1", "degraded"

    return "t1", "degraded"


def main() -> None:
    parser = argparse.ArgumentParser(description="Validacion de tiempos script vs Prometheus")
    parser.add_argument("--input-csv", required=True, help="CSV de entrada con tiempos por corrida")
    parser.add_argument("--prom-url", default="http://localhost:9090", help="URL base de Prometheus")
    parser.add_argument("--query", default=DEFAULT_QUERY, help="PromQL a consultar")
    parser.add_argument(
        "--prometheus-mode",
        choices=["delta", "first-one"],
        default="delta",
        help="delta para A/B; first-one para C",
    )
    parser.add_argument("--app-name", default="nginx-demo", help="Nombre de la app para first-one")
    parser.add_argument("--step", default="15s", help="Paso para query_range")
    parser.add_argument("--margin", type=float, default=15.0, help="Margen permitido en segundos")
    parser.add_argument(
        "--end-margin-s",
        type=float,
        default=0.0,
        help=(
            "Segundos a sumar al final de la ventana de consulta a Prometheus "
            "antes de buscar la primera muestra (modo first-one). Compensa el "
            "desfase entre la detección event-driven del script y el siguiente "
            "scrape_interval de Prometheus. No afecta el modo delta."
        ),
    )
    parser.add_argument("--start-column", default=None, help="Columna de inicio si el CSV no usa t_inicio_iso")
    parser.add_argument("--end-column", default=None, help="Columna de fin si el CSV no usa t_fin_iso")
    parser.add_argument(
        "--value-column",
        default=None,
        help="Columna del CSV con la duracion del script a comparar (si no se indica, se infiere)",
    )
    parser.add_argument("--output-csv", default="prometheus_validation.csv", help="CSV de salida")
    args = parser.parse_args()

    if args.prometheus_mode == "first-one":
        if args.step == "15s":
            args.step = "1s"
        if args.margin == 15.0:
            args.margin = 2.0

    df = pd.read_csv(args.input_csv)

    run_col = resolve_column(df, "run_id", ["id", "run"])
    t0_col = resolve_column(
        df,
        args.start_column or "t_inicio_iso",
        ["inicio_iso", "start_iso", "t0_push_s", "injection_epoch", "deletion_epoch", "t2_revert_push_s"],
    )
    t1_col = resolve_column(
        df,
        args.end_column or "t_fin_iso",
        ["fin_iso", "end_iso", "t1_degraded_s", "t3_healthy_synced_s", "t4_pods_ready_s", "t5_http_first200_s"],
    )
    value_col = resolve_duration_column(df, args.value_column)

    first_one_profile = None
    if args.prometheus_mode == "first-one":
        first_one_profile = infer_first_one_profile(value_col)
        if args.query == DEFAULT_QUERY:
            stage, health = first_one_profile
            if health == "healthy":
                args.query = DEFAULT_HEALTHY_STATE_QUERY_TEMPLATE.replace("{app}", args.app_name)
            else:
                args.query = DEFAULT_STATE_QUERY_TEMPLATE.replace("{app}", args.app_name)
        if args.start_column is None and args.end_column is None:
            if first_one_profile[0] == "t3":
                t0_col = resolve_column(df, "t2_revert_push_s", ["t2_revert_push_s"])
                t1_col = resolve_column(df, "t3_healthy_synced_s", ["t3_healthy_synced_s"])
            else:
                t0_col = resolve_column(df, "t0_push_s", ["t0_push_s"])
                t1_col = resolve_column(df, "t1_degraded_s", ["t1_degraded_s"])

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
        end_s_query = end_s
        if args.prometheus_mode == "first-one" and end_s is not None:
            end_s_query = end_s + args.end_margin_s

        t_prom = None
        if start_s is not None and end_s is not None and end_s > start_s:
            try:
                if args.prometheus_mode == "first-one":
                    t_prom = get_prometheus_first_one_timestamp(
                        prom_base_url=args.prom_url,
                        query_expr=args.query,
                        start_s=start_s,
                        end_s=end_s_query,
                        step=args.step,
                    )
                else:
                    t_prom = get_prometheus_range_delta(
                        prom_base_url=args.prom_url,
                        query_expr=args.query,
                        start_s=start_s,
                        end_s=end_s,
                        step=args.step,
                    )
            except requests.RequestException:
                t_prom = None

        delta = None
        within_margin = False
        if pd.notna(t_script) and t_prom is not None:
            delta = float(t_script) - float(t_prom)
            within_margin = abs(delta) <= args.margin

        rows_out.append(
            {
                "run_id": run_id,
                "t_script_s": float(t_script) if pd.notna(t_script) else "",
                "t_prometheus_s": round(t_prom, 6) if t_prom is not None else "",
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
                "t_prometheus_s",
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
    print(f"Delta promedio (script - Prometheus): {delta_prom:.3f}s")


if __name__ == "__main__":
    main()
