#!/usr/bin/env python3
"""
Analiza CSVs de validacion Prometheus por escenario y condicion/modo.

Uso (3 escenarios):
  python3 experiments/pruebas_reales/prometheus/analyze_prometheus_validations.py \
    --pair experiments/pruebas_reales/results/scenario-a-20260523-235537.csv experiments/pruebas_reales/results/prometheus-validation-a-20260523-235537.csv \
    --pair experiments/pruebas_reales/results/scenario-b-argocd-20260522-014828.csv experiments/pruebas_reales/results/prometheus-validation-b-argocd-20260522-014828.csv \
    --pair experiments/pruebas_reales/results/scenario-c-20260523-221026.csv experiments/pruebas_reales/results/prometheus-validation-c-20260523-221026.csv \
    --output-csv experiments/pruebas_reales/results/prometheus-analysis-summary.csv

Notas:
- Alinea filas por orden entre CSV de escenario y CSV de validacion.
- Considera dato Prometheus real cuando t_prometheus_s > 0.
"""

import argparse
import os
from typing import Optional

import numpy as np
import pandas as pd


def infer_scenario_name(path: str) -> str:
    name = os.path.basename(path).lower()
    if "scenario-a-" in name:
        return "A"
    if "scenario-b-" in name:
        return "B"
    if "scenario-c-" in name:
        return "C"
    return "UNK"


def build_condition_labels(df: pd.DataFrame, scenario_name: str) -> pd.Series:
    n = len(df)
    if n == 0:
        return pd.Series(dtype=str)

    if scenario_name == "A":
        if "condition" in df.columns and "mode" in df.columns:
            return df["condition"].astype(str) + "-" + df["mode"].astype(str)
        if "condition" in df.columns:
            return df["condition"].astype(str)

    if scenario_name == "B":
        if "mode" in df.columns:
            return pd.Series(["B-" + str(m) for m in df["mode"].astype(str)], index=df.index)
        if "group" in df.columns:
            return pd.Series(["B-" + str(g) for g in df["group"].astype(str)], index=df.index)
        return pd.Series(["B-unknown"] * n, index=df.index)

    if scenario_name == "C":
        if "mode" in df.columns:
            return pd.Series(["C-" + str(m) for m in df["mode"].astype(str)], index=df.index)
        return pd.Series(["C-unknown"] * n, index=df.index)

    if "condition" in df.columns and "mode" in df.columns:
        return df["condition"].astype(str) + "-" + df["mode"].astype(str)
    if "mode" in df.columns:
        return pd.Series(["UNK-" + str(m) for m in df["mode"].astype(str)], index=df.index)
    return pd.Series(["UNK"] * n, index=df.index)


def detect_prom_col(df: pd.DataFrame) -> Optional[str]:
    for col in ["t_prometheus_s", "t_prometheus_e2e_s"]:
        if col in df.columns:
            return col
    return None


def to_bool_series(s: pd.Series) -> pd.Series:
    return s.astype(str).str.strip().str.lower().isin(["true", "1", "yes"])


def analyze_pair(scenario_csv: str, prom_csv: str) -> pd.DataFrame:
    base_df = pd.read_csv(scenario_csv)
    prom_df = pd.read_csv(prom_csv)

    prom_col = detect_prom_col(prom_df)
    if prom_col is None:
        raise ValueError(
            f"El archivo {prom_csv} no tiene columna t_prometheus_s ni t_prometheus_e2e_s"
        )

    n = min(len(base_df), len(prom_df))
    if n == 0:
        return pd.DataFrame()

    base_df = base_df.iloc[:n].copy().reset_index(drop=True)
    prom_df = prom_df.iloc[:n].copy().reset_index(drop=True)

    scenario_name = infer_scenario_name(scenario_csv)
    cond = build_condition_labels(base_df, scenario_name)

    t_script = pd.to_numeric(prom_df.get("t_script_s"), errors="coerce")
    t_prom = pd.to_numeric(prom_df.get(prom_col), errors="coerce")

    if "delta_s" in prom_df.columns:
        delta = pd.to_numeric(prom_df.get("delta_s"), errors="coerce")
    else:
        delta = t_script - t_prom

    if "dentro_margen_15s" in prom_df.columns:
        within_15 = to_bool_series(prom_df.get("dentro_margen_15s"))
    else:
        within_15 = (delta.abs() <= 15)

    work = pd.DataFrame(
        {
            "condition_mode": cond,
            "t_script_s": t_script,
            "t_prom_s": t_prom,
            "delta_s": delta,
            "within_15": within_15,
        }
    )

    rows = []
    for key, g in work.groupby("condition_mode", dropna=False):
        n_total = len(g)
        real_mask = g["t_prom_s"].notna() & (g["t_prom_s"] > 0)
        g_real = g[real_mask]
        n_real = len(g_real)

        delta_mean = float(g_real["delta_s"].mean()) if n_real else np.nan
        delta_max = float(g_real["delta_s"].abs().max()) if n_real else np.nan

        within_pct = float(g["within_15"].mean() * 100.0) if n_total else np.nan
        prom_zeros = int(((g["t_prom_s"] == 0) & g["t_prom_s"].notna()).sum())

        script_mean_real = float(g_real["t_script_s"].mean()) if n_real else np.nan
        prom_mean_real = float(g_real["t_prom_s"].mean()) if n_real else np.nan

        rows.append(
            {
                "scenario_csv": os.path.basename(scenario_csv),
                "prometheus_csv": os.path.basename(prom_csv),
                "condition_mode": str(key),
                "n_total": int(n_total),
                "n_prom_real": int(n_real),
                "n_t_prom_zero": int(prom_zeros),
                "delta_mean_s": round(delta_mean, 6) if pd.notna(delta_mean) else "",
                "delta_max_abs_s": round(delta_max, 6) if pd.notna(delta_max) else "",
                "pct_within_15s": round(within_pct, 2) if pd.notna(within_pct) else "",
                "t_script_mean_real_s": round(script_mean_real, 6)
                if pd.notna(script_mean_real)
                else "",
                "t_prom_mean_real_s": round(prom_mean_real, 6)
                if pd.notna(prom_mean_real)
                else "",
            }
        )

    return pd.DataFrame(rows)


def print_markdown(df: pd.DataFrame) -> None:
    if df.empty:
        print("Sin datos para mostrar")
        return

    cols = [
        "condition_mode",
        "n_total",
        "n_prom_real",
        "n_t_prom_zero",
        "delta_mean_s",
        "delta_max_abs_s",
        "pct_within_15s",
        "t_script_mean_real_s",
        "t_prom_mean_real_s",
    ]

    print("\n### Resumen validacion Prometheus por condicion")
    print("| " + " | ".join(cols) + " |")
    print("| " + " | ".join(["---"] * len(cols)) + " |")
    for _, r in df[cols].iterrows():
        vals = [str(r[c]) for c in cols]
        print("| " + " | ".join(vals) + " |")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Analiza validaciones Prometheus por condicion/modo para A/B/C"
    )
    parser.add_argument(
        "--pair",
        nargs=2,
        action="append",
        metavar=("SCENARIO_CSV", "PROMETHEUS_CSV"),
        required=True,
        help="Par de archivos: CSV de escenario y CSV de validacion Prometheus",
    )
    parser.add_argument(
        "--output-csv",
        default="",
        help="Ruta opcional para guardar resumen consolidado en CSV",
    )
    args = parser.parse_args()

    all_rows = []
    for scenario_csv, prom_csv in args.pair:
        print(f"\n[INFO] Analizando par:\n  scenario={scenario_csv}\n  prometheus={prom_csv}")
        part = analyze_pair(scenario_csv, prom_csv)
        if part.empty:
            print("  [WARN] Sin filas utiles en este par")
            continue
        all_rows.append(part)

    if not all_rows:
        print("No se generaron resultados")
        return

    out = pd.concat(all_rows, ignore_index=True)
    out = out.sort_values(["scenario_csv", "condition_mode"]).reset_index(drop=True)

    print_markdown(out)

    if args.output_csv:
        out.to_csv(args.output_csv, index=False)
        print(f"\n[OK] Resumen guardado en: {args.output_csv}")


if __name__ == "__main__":
    main()
