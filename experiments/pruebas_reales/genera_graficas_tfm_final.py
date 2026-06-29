#!/usr/bin/env python3
"""
graficas_tfm.py — TFM GitOps/ArgoCD (versión reducida)

Genera 11 figuras (escenarios A, B, C) y un Markdown con 7 tablas,
calculando los valores directamente desde los CSV más recientes.

Uso:
    python graficas_tfm.py --results-dir /ruta/csvs/
"""

import argparse
import glob
import os
import sys

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.lines import Line2D
from scipy import stats

# ── Colores y targets ──────────────────────────────────────────────────────
AZUL, MORADO, ROJO, NARANJA, GRIS = "#2E86AB", "#7B2D8B", "#C73E1D", "#F18F01", "#6C757D"

TARGETS = {"A1_normal": 10, "A1_stress": 30, "A2_normal": 5, "A2_stress": 15, "B_normal": 30}

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

plt.rcParams.update({"font.size": 12, "axes.titlesize": 13, "figure.dpi": 100,
                     "figure.constrained_layout.use": True, "axes.grid": True,
                     "grid.alpha": 0.3})


# ── Carga de datos ─────────────────────────────────────────────────────────
def csv_reciente(carpeta, incluye, etiqueta, excluye=()):
    """CSV más reciente cuyo nombre contiene cualquiera de 'incluye' y ninguno de 'excluye'.
    Imprime qué escenario tomó qué archivo, o avisa si no encontró ninguno."""
    patrones = (incluye,) if isinstance(incluye, str) else tuple(incluye)
    archivos = [f for f in glob.glob(f"{carpeta}/*.csv")
                if any(p in os.path.basename(f).lower() for p in patrones)
                and not any(x in os.path.basename(f).lower() for x in excluye)]
    if not archivos:
        buscados = " | ".join(patrones)
        print(f"  [WARN] {etiqueta}: no se encontró ningún CSV (buscando '{buscados}')")
        return pd.DataFrame()
    ruta = max(archivos, key=os.path.getmtime)
    print(f"  [OK]   {etiqueta} -> {os.path.basename(ruta)}")
    return pd.read_csv(ruta)


def leer_csv_explicit(ruta, etiqueta):
    if not ruta:
        return pd.DataFrame()
    if not os.path.exists(ruta):
        print(f"  [WARN] {etiqueta}: no existe {ruta}")
        return pd.DataFrame()
    print(f"  [OK]   {etiqueta} -> {os.path.basename(ruta)}")
    return pd.read_csv(ruta)


def _enriquecer_c_nuevo(c_nuevo):
    """Normaliza tipos y agrega columnas derivadas del escenario C rediseñado."""
    if c_nuevo.empty:
        return c_nuevo
    if "mode" in c_nuevo.columns:
        c_nuevo["mode"] = c_nuevo["mode"].astype(str).str.lower()
    c_nuevo["tiempo_deteccion_s"] = pd.to_numeric(c_nuevo["tiempo_deteccion_s"], errors="coerce")
    c_nuevo["tiempo_recuperacion_post_revert_s"] = pd.to_numeric(
        c_nuevo["tiempo_recuperacion_post_revert_s"], errors="coerce"
    )
    for col in ("degraded_ok", "recovery_ok", "http_ok"):
        if col in c_nuevo.columns:
            c_nuevo[col] = c_nuevo[col].astype(str).str.lower().eq("true")
    # Booleano dedicado para "pods llegaron a Ready", derivado de t4_pods_ready_s.
    # No reusar http_ok aquí: son etapas distintas (T4 vs T5) y deben reportarse por separado.
    if "t4_pods_ready_s" in c_nuevo.columns:
        c_nuevo["pods_ready_ok"] = pd.to_numeric(c_nuevo["t4_pods_ready_s"], errors="coerce").notna()
    return c_nuevo


def _enriquecer_c_legacy(c_legacy):
    """Normaliza tipos y agrega columnas derivadas del escenario C histórico (selfHeal)."""
    if c_legacy.empty:
        return c_legacy
    c_legacy["c1_degraded_s"] = pd.to_numeric(c_legacy["c1_degraded_s"], errors="coerce")  # TIMEOUT → NaN
    c_legacy["c2_rollback_s"] = pd.to_numeric(c_legacy["c2_rollback_s"], errors="coerce")
    c_legacy["t_rollback"] = c_legacy["rollback_trigger_epoch"] - c_legacy["injection_epoch"]
    c_legacy["c1_timeout"] = c_legacy["c1_degraded_s"].isna()
    return c_legacy


def cargar_datos(carpeta):
    # Acepta variantes con y sin guion para mayor robustez de nombres.
    a = csv_reciente(carpeta, ("scenario-a", "scenarioa"), "Escenario A (drift)", excluye=("argocd",))
    if not a.empty:
        a["tiempo_s"] = pd.to_numeric(a["spec_recovery_s"], errors="coerce")
        a["exito"] = a["spec_ok"].astype(str).str.lower().eq("true") & \
                     a["pods_ok"].astype(str).str.lower().eq("true")

    argo = csv_reciente(carpeta, "argocd", "Escenario B ArgoCD (RTO)")
    if not argo.empty:
        argo["rto_s"] = pd.to_numeric(argo["rto_s"], errors="coerce")          # TIMEOUT → NaN
        argo["spec_recreated_s"] = pd.to_numeric(argo["spec_recreated_s"], errors="coerce")
        argo["exito"] = argo["rto_ok"].astype(str).str.lower().eq("true")

    ctrl = csv_reciente(carpeta, "control", "Escenario B Control")
    if not ctrl.empty:
        # éxito de control = NO recuperarse (comportamiento esperado sin GitOps)
        ctrl["sin_recuperacion"] = ctrl["deployment_recreated"].astype(str).str.lower().eq("false")

    c_nuevo = csv_reciente(carpeta, ("scenario-c", "scenarioc"), "Escenario C nuevo (git revert)")
    c_nuevo = _enriquecer_c_nuevo(c_nuevo)

    return a, argo, ctrl, pd.DataFrame(), c_nuevo


def cargar_datos_c_explicit(c_legacy_csv, c_new_csv, results_dir):
    c_nuevo = leer_csv_explicit(c_new_csv, "Escenario C nuevo (git revert)") if c_new_csv else csv_reciente(
        results_dir, ("scenario-c", "scenarioc"), "Escenario C nuevo (git revert)"
    )
    c_nuevo = _enriquecer_c_nuevo(c_nuevo)

    return pd.DataFrame(), c_nuevo


# ── Estadística ────────────────────────────────────────────────────────────
def resumen(serie):
    """(n, media, mediana, sigma, ic_lo, ic_hi, p90, p95). IC95 vía t-Student."""
    v = serie.dropna()
    n = len(v)
    if n == 0:
        return (0,) + (0.0,) * 7
    media, mediana, sigma = float(v.mean()), float(v.median()), float(v.std(ddof=1)) if n > 1 else 0.0
    if n <= 1 or sigma == 0:
        lo = hi = media
    else:
        lo, hi = stats.t.interval(0.95, n - 1, loc=media, scale=sigma / np.sqrt(n))
    return n, media, mediana, sigma, float(lo), float(hi), \
           float(np.percentile(v, 90)), float(np.percentile(v, 95))


def guardar(fig, ruta):
    fig.savefig(ruta, dpi=300, bbox_inches="tight")
    plt.close(fig)
    print(f"  ✓ {os.path.basename(ruta)}")


def histograma(ax, datos, titulo, color):
    v = datos.dropna()
    if v.empty:
        ax.text(0.5, 0.5, "Sin datos", ha="center", transform=ax.transAxes)
        ax.set_title(titulo)
        return
    media = float(v.mean())
    ax.hist(v, bins=max(5, min(14, v.nunique())), color=color, alpha=0.55,
            edgecolor="white", density=True)
    if v.std() > 0.1:
        xs = np.linspace(max(0, v.min() - 1), v.max() + 2, 300)
        ax.plot(xs, stats.gaussian_kde(v)(xs), color=color, linewidth=2.5)
    ax.axvline(media, color="black", ls="--", lw=2, label=f"μ = {media:.2f} s")
    # Eje X ceñido a la zona de datos (margen 10%) para que las barras no queden aplastadas.
    margen = max((float(v.max()) - float(v.min())) * 0.1, 0.5)
    ax.set_xlim(max(0, float(v.min()) - margen), float(v.max()) + margen)
    ax.set_title(f"{titulo}\nn={len(v)}, μ={media:.2f}s, σ={v.std():.2f}s")
    ax.set_xlabel("Tiempo (s)")
    ax.set_ylabel("Densidad")
    ax.legend(fontsize=10)


def boxplot(ax, grupos, etiquetas, colores, titulo, ylabel):
    pares = [(g.dropna(), e, c) for g, e, c in zip(grupos, etiquetas, colores) if g.dropna().size]
    if not pares:
        ax.text(0.5, 0.5, "Sin datos", ha="center", transform=ax.transAxes)
        ax.set_title(titulo)
        return
    datos, etiq, cols = zip(*pares)
    bp = ax.boxplot([d.values for d in datos], patch_artist=True, showmeans=True,
                    meanprops=dict(marker="D", markerfacecolor="white", markeredgecolor="black"),
                    medianprops=dict(color="black", linewidth=2))
    for caja, col in zip(bp["boxes"], cols):
        caja.set_facecolor(col)
        caja.set_alpha(0.65)
    for i, d in enumerate(datos, 1):
        ax.text(i, float(d.quantile(0.75)), f"Med={d.median():.1f}s", ha="center", fontsize=9,
                bbox=dict(boxstyle="round,pad=0.2", fc="white", alpha=0.8))
    ax.set_xticks(range(1, len(etiq) + 1))
    ax.set_xticklabels(etiq)
    ax.set_title(titulo)
    ax.set_ylabel(ylabel)
    ax.set_ylim(bottom=0)


# ══ ESCENARIO A ════════════════════════════════════════════════════════════
def fig_hist_A(a, cond, outdir, n_fig):
    sub = "k8s watch" if cond == "A1" else "refresh / webhook"
    fig, ax = plt.subplots(1, 2, figsize=(14, 6))
    fig.suptitle(f"Escenario {cond} — Config Drift ({sub})", fontsize=14, fontweight="bold")
    base = a[a["condition"] == cond] if not a.empty else pd.DataFrame()
    for i, (modo, etiqueta) in enumerate((("normal", "Normal"), ("stress", "Estrés"))):
        serie = base[base["mode"] == modo]["tiempo_s"] if not base.empty else pd.Series(dtype=float)
        color = AZUL if modo == "normal" else ROJO
        histograma(ax[i], serie, f"Condición {etiqueta}", color)
    guardar(fig, f"{outdir}/figA{n_fig}_histograma_{cond}.png")


def figA3_boxplot(a, outdir):
    fig, ax = plt.subplots(figsize=(12, 7))
    fig.suptitle("Escenario A — Normal vs Estrés (A1 y A2)", fontsize=14, fontweight="bold")
    grupos, etiq, cols = [], [], []
    if not a.empty:
        for cond in ("A1", "A2"):
            for modo in ("normal", "stress"):
                grupos.append(a[(a["condition"] == cond) & (a["mode"] == modo)]["tiempo_s"])
                etiq.append(f"{cond}\n{modo}")
                cols.append(AZUL if modo == "normal" else ROJO)
    boxplot(ax, grupos, etiq, cols, "spec_recovery_s por condición", "Tiempo (s)")
    guardar(fig, f"{outdir}/figA3_boxplot_A.png")


def figA4_scatter(a, outdir):
    if a.empty:
        return
    v1 = a[(a["condition"] == "A1") & (a["mode"] == "normal")]["tiempo_s"].dropna()
    v2 = a[(a["condition"] == "A2") & (a["mode"] == "normal")]["tiempo_s"].dropna()
    if v1.empty or v2.empty:
        return
    fig, ax = plt.subplots(figsize=(10, 7))
    rng = np.random.default_rng(0)
    ax.scatter(rng.normal(1, 0.05, len(v1)), v1, alpha=0.65, s=70, color=AZUL,
               edgecolor="white", label="A1 — k8s watch")
    ax.scatter(rng.normal(2, 0.05, len(v2)), v2, alpha=0.65, s=70, color="#1D5A8F",
               edgecolor="white", label="A2 — refresh")
    ax.hlines(v1.mean(), 0.8, 1.2, colors=AZUL, lw=2.5, ls="--", label=f"μ A1 = {v1.mean():.2f} s")
    ax.hlines(v2.mean(), 1.8, 2.2, colors="#1D5A8F", lw=2.5, ls="--", label=f"μ A2 = {v2.mean():.2f} s")
    ax.set_xticks([1, 2])
    ax.set_xticklabels(["A1 — k8s watch", "A2 — refresh"])
    ax.set_ylabel("spec_recovery_s (s)")
    ax.set_title("Comparativa A1 vs A2 — condición normal", fontweight="bold")
    ax.set_xlim(0.5, 2.5)
    ax.legend(fontsize=10)
    guardar(fig, f"{outdir}/figA4_scatter_A1_vs_A2.png")


# ══ ESCENARIO B ════════════════════════════════════════════════════════════
def figB1_rto_normal(argo, ctrl, outdir):
    fig, ax = plt.subplots(1, 2, figsize=(14, 6))
    fig.suptitle("Escenario B — Tiempo de recuperacion observado, ArgoCD (normal) vs Control", fontsize=14, fontweight="bold")
    serie = argo[argo["mode"] == "normal"]["rto_s"] if not argo.empty else pd.Series(dtype=float)
    histograma(ax[0], serie, "ArgoCD — Tiempo de recuperacion observado (normal)", MORADO)
    if not ctrl.empty:
        total = len(ctrl)
        sin_rec = int(ctrl["sin_recuperacion"].sum())
        con_rec = total - sin_rec
        barras = ax[1].bar(["Sin recuperación\n(esperado)", "Con recuperación\n(inesperado)"],
                           [sin_rec, con_rec], color=[ROJO, MORADO], alpha=0.85, width=0.5)
        for b, val in zip(barras, [sin_rec, con_rec]):
            ax[1].text(b.get_x() + b.get_width() / 2, b.get_height() + 0.4,
                       f"{val} ({val / total * 100:.0f}%)", ha="center", fontweight="bold")
        ax[1].set_title(f"Control — sin ArgoCD\nn={total}, 0% recuperación automática")
        ax[1].set_ylabel("N° de ejecuciones")
        ax[1].set_ylim(0, total + 6)
    guardar(fig, f"{outdir}/figB1_rto_normal.png")


def figB2_stress(argo, outdir):
    if argo.empty:
        return
    sel = argo[argo["mode"] == "stress"]
    if sel.empty:
        return
    n = len(sel)
    spec = sel["spec_recreated_s"].dropna()
    timeout = int(sel["rto_s"].isna().sum())

    fig, ax = plt.subplots(1, 2, figsize=(14, 6))
    fig.suptitle("Escenario B stress — ArgoCD bajo presión", fontsize=14, fontweight="bold")
    if not spec.empty:
        ax[0].hist(spec, bins=max(3, spec.nunique()), color=MORADO, alpha=0.65, edgecolor="white")
        ax[0].axvline(spec.mean(), color="black", ls="--", lw=2, label=f"μ = {spec.mean():.1f} s")
        ax[0].set_title(f"Fase 1 — Reconciliación (ArgoCD)\nn={len(spec)}, μ={spec.mean():.1f}s → EXITOSO")
        ax[0].set_xlabel("spec_recreated_s (s)")
        ax[0].set_ylabel("N° de ejecuciones")
        ax[0].legend(fontsize=10)
    barras = ax[1].bar(["Pods Ready\n(recuperacion completa)", "TIMEOUT\n(pods no Ready)"],
                       [n - timeout, timeout], color=[MORADO, ROJO], alpha=0.85, width=0.5)
    for b, val in zip(barras, [n - timeout, timeout]):
        ax[1].text(b.get_x() + b.get_width() / 2, b.get_height() + 0.2,
                   f"{val} ({val / n * 100:.0f}%)", ha="center", fontweight="bold")
    ax[1].set_title("Tiempo de recuperacion observado, medio por grupo\n(stress = solo fase de reconciliacion ArgoCD)")
    ax[1].set_ylabel("N° de ejecuciones")
    ax[1].set_ylim(0, n + 4)
    guardar(fig, f"{outdir}/figB2_bstress_spec_recreated.png")


def figB3_comparativa(argo, ctrl, outdir):
    fig, ax = plt.subplots(1, 2, figsize=(14, 7))
    fig.suptitle("Escenario B — Comparativa ArgoCD vs Control", fontsize=14, fontweight="bold")

    tasa_n = float(argo[argo["mode"] == "normal"]["exito"].mean() * 100) if not argo.empty else 0
    tasa_s = float(argo[argo["mode"] == "stress"]["exito"].mean() * 100) if not argo.empty else 0
    tasa_c = float((1 - ctrl["sin_recuperacion"].mean()) * 100) if not ctrl.empty else 0
    vals = [tasa_n, tasa_s, tasa_c]
    barras = ax[0].barh(["ArgoCD normal", "ArgoCD stress", "Control\n(sin GitOps)"],
                        vals, color=[MORADO, ROJO, ROJO], alpha=0.85, height=0.45)
    for b, val in zip(barras, vals):
        ax[0].text(val + 1.5, b.get_y() + b.get_height() / 2, f"{val:.0f} %", va="center", fontweight="bold")
    ax[0].set_xlim(0, 118)
    ax[0].set_xlabel("Tasa de recuperación automática (%)")
    ax[0].set_title("Recuperación automática por grupo")

    rto_n = float(argo[argo["mode"] == "normal"]["rto_s"].mean()) if not argo.empty else 0
    spec_s = float(argo[argo["mode"] == "stress"]["spec_recreated_s"].mean()) if not argo.empty else 0
    vals2 = [rto_n, spec_s, 120.0]
    barras2 = ax[1].barh(["ArgoCD normal\n(recuperacion completa)", "ArgoCD stress\n(reconciliación)", "Control\n(timeout 120 s)"],
                         vals2, color=[MORADO, ROJO, ROJO], alpha=0.85, height=0.45)
    for b, val in zip(barras2, vals2):
        ax[1].text(val + 1, b.get_y() + b.get_height() / 2, f"{val:.1f} s", va="center", fontweight="bold")
    ax[1].axvline(TARGETS["B_normal"], color="green", ls="--", lw=1.8, label=f"RTO (objetivo) ≤{TARGETS['B_normal']} s")
    ax[1].set_xlim(0, max(vals2) * 1.4)
    ax[1].set_xlabel("Tiempo (s)")
    ax[1].set_title("Tiempo de recuperacion observado, medio por grupo")
    ax[1].legend(fontsize=10)
    guardar(fig, f"{outdir}/figB3_comparativa_argocd_control.png")


def figB4_intervalos(a, argo, outdir):
    puntos = []
    if not a.empty:
        for cond in ("A1", "A2"):
            for modo in ("normal", "stress"):
                n, media, *_, lo, hi, _, _ = resumen(a[(a["condition"] == cond) & (a["mode"] == modo)]["tiempo_s"])
                if n:
                    puntos.append((cond, modo, media, lo, hi, TARGETS[f"{cond}_{modo}"]))
    if not argo.empty:
        n, media, *_, lo, hi, _, _ = resumen(argo[argo["mode"] == "normal"]["rto_s"])
        if n:
            puntos.append(("B", "normal", media, lo, hi, TARGETS["B_normal"]))
    if not puntos:
        return

    fig, ax = plt.subplots(figsize=(12, 7))
    gx = {"A1": 0, "A2": 3, "B": 6}
    dx = {"normal": -0.45, "stress": 0.45}
    mk = {"normal": "o", "stress": "^"}
    col = {"normal": AZUL, "stress": ROJO}
    for cond, modo, media, lo, hi, target in puntos:
        x = gx[cond] + dx[modo]
        ax.errorbar(x, media, yerr=[[max(0, media - lo)], [max(0, hi - media)]],
                    fmt=mk[modo], color=col[modo], markersize=10, capsize=6, lw=2)
        ax.annotate(f"{media:.1f} s", (x, hi + 0.5), ha="center", fontsize=9, color=col[modo])
        ax.hlines(target, x - 0.65, x + 0.65, colors="gray",
                  ls=":" if modo == "normal" else "--", lw=1.8)
        ax.text(x + 0.7, target, f"T={target} s", va="center", fontsize=8.5, color="gray")
    ax.set_xticks(list(gx.values()))
    ax.set_xticklabels(["A1\n(k8s watch)", "A2\n(refresh)", "B\n(RTO normal)"])
    ax.set_ylabel("Tiempo (s)")
    ax.set_ylim(bottom=0)
    ax.set_title("Medias con IC 95% y Targets\n(B stress excluido por TIMEOUT)", fontweight="bold")
    ax.legend(handles=[
        Line2D([0], [0], marker="o", color=AZUL, lw=0, markersize=10, label="Normal (x̄ ± IC 95%)"),
        Line2D([0], [0], marker="^", color=ROJO, lw=0, markersize=10, label="Estrés (x̄ ± IC 95%)"),
        Line2D([0], [0], color="gray", ls=":", label="Target normal"),
        Line2D([0], [0], color="gray", ls="--", label="Target estrés"),
    ], fontsize=10)
    guardar(fig, f"{outdir}/figB4_intervalos_confianza.png")


def figC1_histograma_deteccion(c_nuevo, outdir):
    if c_nuevo.empty:
        return
    fig, axes = plt.subplots(1, 2, figsize=(14, 6))
    fig.suptitle("Escenario C1 — Detección de Degraded tras inyección por Git", fontsize=14, fontweight="bold")
    histograma(axes[0], c_nuevo[c_nuevo["mode"] == "normal"]["tiempo_deteccion_s"], "Condición Normal", AZUL)
    histograma(axes[1], c_nuevo[c_nuevo["mode"] == "stress"]["tiempo_deteccion_s"], "Condición Estrés", ROJO)
    guardar(fig, f"{outdir}/figC1_histograma_deteccion.png")


def figC2_histograma_recuperacion(c_nuevo, outdir):
    if c_nuevo.empty:
        return
    fig, axes = plt.subplots(1, 2, figsize=(14, 6))
    fig.suptitle("Escenario C2 — Recuperación post-revert", fontsize=14, fontweight="bold")
    histograma(axes[0], c_nuevo[c_nuevo["mode"] == "normal"]["tiempo_recuperacion_post_revert_s"], "Condición Normal", AZUL)
    histograma(axes[1], c_nuevo[c_nuevo["mode"] == "stress"]["tiempo_recuperacion_post_revert_s"], "Condición Estrés", ROJO)
    guardar(fig, f"{outdir}/figC2_histograma_recuperacion.png")


def figC3_boxplot_normal_vs_stress(c_nuevo, outdir):
    if c_nuevo.empty:
        return
    fig, ax = plt.subplots(1, 1, figsize=(10, 7))
    fig.suptitle("Escenario C3 — Boxplot recuperación normal vs estrés", fontsize=14, fontweight="bold")

    boxplot(
        ax,
        [
            c_nuevo[c_nuevo["mode"] == "normal"]["tiempo_recuperacion_post_revert_s"],
            c_nuevo[c_nuevo["mode"] == "stress"]["tiempo_recuperacion_post_revert_s"],
        ],
        ["Normal", "Estrés"],
        [AZUL, ROJO],
        "Tiempo de recuperación post-revert",
        "Tiempo (s)",
    )

    guardar(fig, f"{outdir}/figC3_boxplot_recuperacion_normal_vs_stress.png")


# ══ TABLAS MARKDOWN ════════════════════════════════════════════════════════
def tabla_md(titulo, columnas, filas):
    lineas = [f"### {titulo}", "", "| " + " | ".join(columnas) + " |",
              "| " + " | ".join(["---"] * len(columnas)) + " |"]
    for f in filas:
        lineas.append("| " + " | ".join(str(f.get(col, "—")) for col in columnas) + " |")
    return "\n".join(lineas)


def fmt(v):
    if v is None or (isinstance(v, float) and np.isnan(v)):
        return "—"
    return f"{float(v):.2f}"


def generar_tablas(a, argo, ctrl, c_legacy, c_nuevo, results_dir, ruta_md):
    secciones = []

    # Tabla 1 — Escenario A
    cols_a = ["Escenario", "Modo", "n", "μ (s)", "Mediana (s)", "σ (s)", "IC95 lo",
              "IC95 hi", "P90 (s)", "P95 (s)", "Éxito (%)", "Target (s)", "Cumple"]
    filas_a = []
    if not a.empty:
        for cond in ("A1", "A2"):
            for modo in ("normal", "stress"):
                sel = a[(a["condition"] == cond) & (a["mode"] == modo)]
                n, media, med, sig, lo, hi, p90, p95 = resumen(sel["tiempo_s"])
                if n == 0:
                    continue
                target = TARGETS[f"{cond}_{modo}"]
                filas_a.append({"Escenario": f"A — {cond}", "Modo": modo, "n": n,
                                "μ (s)": fmt(media), "Mediana (s)": fmt(med), "σ (s)": fmt(sig),
                                "IC95 lo": fmt(lo), "IC95 hi": fmt(hi), "P90 (s)": fmt(p90),
                                "P95 (s)": fmt(p95), "Éxito (%)": fmt(sel["exito"].mean() * 100),
                                "Target (s)": fmt(target), "Cumple": "Sí" if p95 <= target else "No"})
    secciones.append(tabla_md("Tabla 1 — Resumen numérico (Escenario A)", cols_a, filas_a))

    # Tabla 2 — Escenario B normal
    filas_b = []
    if not argo.empty:
        sel = argo[argo["mode"] == "normal"]
        n, media, med, sig, lo, hi, p90, p95 = resumen(sel["rto_s"])
        if n:
            target = TARGETS["B_normal"]
            filas_b.append({"Escenario": "B — ArgoCD", "Modo": "normal", "n": n,
                            "μ (s)": fmt(media), "Mediana (s)": fmt(med), "σ (s)": fmt(sig),
                            "IC95 lo": fmt(lo), "IC95 hi": fmt(hi), "P90 (s)": fmt(p90),
                            "P95 (s)": fmt(p95), "Éxito (%)": fmt(sel["exito"].mean() * 100),
                            "Target (s)": fmt(target), "Cumple": "Sí" if p90 <= target else "No"})
    secciones.append(tabla_md("Tabla 2 — Estadística descriptiva (Escenario B, ArgoCD normal)", cols_a, filas_b))

    # Tabla 3 — Comparativa B
    cols_c = ["Grupo", "n", "Tiempo recuperacion obs., medio (s)", "Tasa recuperación (%)", "Target", "Cumple"]
    filas_c = []
    if not argo.empty:
        sn = argo[argo["mode"] == "normal"]
        rto_n = float(sn["rto_s"].mean())
        filas_c.append({"Grupo": "ArgoCD — normal", "n": len(sn), "Tiempo recuperacion obs., medio (s)": fmt(rto_n),
                        "Tasa recuperación (%)": fmt(sn["exito"].mean() * 100),
                        "Target": f"RTO ≤ {TARGETS['B_normal']:.0f}s",
                        "Cumple": "Sí" if rto_n <= TARGETS["B_normal"] else "No"})
        ss = argo[argo["mode"] == "stress"]
        filas_c.append({"Grupo": "ArgoCD — stress", "n": len(ss), "Tiempo recuperacion obs., medio (s)": "TIMEOUT",
                        "Tasa recuperación (%)": fmt(ss["exito"].mean() * 100),
                        "Target": "RTO ≤ 120s (P90)", "Cumple": "No"})
    if not ctrl.empty:
        rec = float((1 - ctrl["sin_recuperacion"].mean()) * 100)
        filas_c.append({"Grupo": "Control (sin ArgoCD)", "n": len(ctrl), "Tiempo recuperacion obs., medio (s)": "∞ (>120s)",
                        "Tasa recuperación (%)": fmt(rec), "Target": "Recovery rate = 0%",
                        "Cumple": "Sí" if rec == 0 else "No"})
    secciones.append(tabla_md("Tabla 3 — Comparativa ArgoCD vs Control (Escenario B)", cols_c, filas_c))

    # Tabla 4 — Escenario C rediseñado
    cols_c = ["Escenario", "Modo", "n", "μ (s)", "Mediana (s)", "σ (s)", "IC95 lo",
              "IC95 hi", "P90 (s)", "P95 (s)", "Éxito (%)", "Target (s)", "Cumple"]
    filas_c = []
    if not c_nuevo.empty:
        for modo, target_det, target_rec in (("normal", 30.0, 60.0), ("stress", 30.0, 120.0)):
            sel = c_nuevo[c_nuevo["mode"] == modo]
            if len(sel) == 0:
                continue

            det = pd.to_numeric(sel["tiempo_deteccion_s"], errors="coerce")
            n, media, mediana, sigma, lo, hi, p90, p95 = resumen(det)
            filas_c.append({
                "Escenario": "C1 — Detección (push→Degraded)",
                "Modo": modo,
                "n": n,
                "μ (s)": fmt(media),
                "Mediana (s)": fmt(mediana),
                "σ (s)": fmt(sigma),
                "IC95 lo": fmt(lo),
                "IC95 hi": fmt(hi),
                "P90 (s)": fmt(p90),
                "P95 (s)": fmt(p95),
                "Éxito (%)": fmt(float(sel["degraded_ok"].mean() * 100.0)),
                "Target (s)": fmt(target_det),
                "Cumple": "Sí" if p95 <= target_det else "No",
            })
        for modo, target_det, target_rec in (("normal", 30.0, 60.0), ("stress", 30.0, 120.0)):
            sel = c_nuevo[c_nuevo["mode"] == modo]
            if len(sel) == 0:
                continue
            rec = pd.to_numeric(sel["tiempo_recuperacion_post_revert_s"], errors="coerce")
            n, media, mediana, sigma, lo, hi, p90, p95 = resumen(rec)
            filas_c.append({
                "Escenario": "C2 — Recuperación (revert→Healthy)",
                "Modo": modo,
                "n": n,
                "μ (s)": fmt(media),
                "Mediana (s)": fmt(mediana),
                "σ (s)": fmt(sigma),
                "IC95 lo": fmt(lo),
                "IC95 hi": fmt(hi),
                "P90 (s)": fmt(p90),
                "P95 (s)": fmt(p95),
                "Éxito (%)": fmt(float(sel["recovery_ok"].mean() * 100.0)),
                "Target (s)": fmt(target_rec),
                "Cumple": "Sí" if p95 <= target_rec else "No",
            })

    secciones.append(tabla_md("Tabla 4 — Resumen numérico (Escenario C, rediseñado)", cols_c, filas_c))

    filas_4b = []
    if not c_nuevo.empty:
        for modo in ("normal", "stress"):
            sel = c_nuevo[c_nuevo["mode"] == modo]
            if len(sel) == 0:
                continue
            n = len(sel)
            filas_4b.append({
                "Modo": modo,
                "n": n,
                "Degraded detectado": f"{int(sel['degraded_ok'].sum())}/{n} ({float(sel['degraded_ok'].mean() * 100):.0f}%)",
                "Rollback completado": f"{int(sel['recovery_ok'].sum())}/{n} ({float(sel['recovery_ok'].mean() * 100):.0f}%)",
                "Pods Ready": f"{int(sel['pods_ready_ok'].sum())}/{n} ({float(sel['pods_ready_ok'].mean() * 100):.0f}%)",
                "HTTP 200×3": f"{int(sel['http_ok'].sum())}/{n} ({float(sel['http_ok'].mean() * 100):.0f}%)",
                "rollback_method": f"{sel['rollback_method'].iloc[0]} ({float((sel['rollback_method'].astype(str) == 'git_revert').mean() * 100):.0f}%)",
            })
    secciones.append(tabla_md("Tabla 4b — Tasa de éxito por etapa (Escenario C)", ["Modo", "n", "Degraded detectado", "Rollback completado", "Pods Ready", "HTTP 200×3", "rollback_method"], filas_4b))

    filas_4c = []
    prom_t1 = os.path.join(results_dir, "prometheus_validation_t1.csv")
    prom_t3 = os.path.join(results_dir, "prometheus_validation_t3.csv")
    if os.path.exists(prom_t1) and os.path.exists(prom_t3):
        for marca, ruta, nota in [
            ("T1 (detección)", prom_t1, "Offset constante = 1 scrape_interval"),
            ("T3 (recuperación)", prom_t3, "1 excepción: desfase de 2s por fase de muestreo, verificado contra la serie cruda"),
        ]:
            dfv = pd.read_csv(ruta)
            if "dentro_margen_15s" in dfv.columns:
                ok = dfv["dentro_margen_15s"].astype(str).str.lower().eq("true")
            else:
                ok = pd.Series(dtype=bool)
            if "delta_s" in dfv.columns:
                delta_vals = pd.to_numeric(dfv["delta_s"], errors="coerce")
            else:
                delta_vals = pd.Series(dtype=float)
            filas_4c.append({
                "Marca": marca,
                "n": len(dfv),
                "Validadas dentro de margen (±2s)": f"{int(ok.sum())}/{len(dfv)}",
                "%": fmt(float(ok.mean() * 100.0) if len(dfv) else 0.0),
                "Delta promedio (s)": fmt(delta_vals.mean()),
                "Nota": nota,
            })
    if filas_4c:
        secciones.append(tabla_md("Tabla 4c — Validación cruzada con Prometheus (Escenario C)", ["Marca", "n", "Validadas dentro de margen (±2s)", "%", "Delta promedio (s)", "Nota"], filas_4c))

    # Tabla 5 — Maestra consolidada: A1, A2 (normal/stress), B normal y C1/C2 en una sola vista.
    cols_m = ["Grupo", "Métrica", "Modo", "n", "μ (s)", "Mediana (s)", "σ (s)",
              "P90 (s)", "P95 (s)", "Éxito (%)", "Target (s)", "Cumple"]
    filas_m = []
    if not a.empty:
        for cond in ("A1", "A2"):
            for modo in ("normal", "stress"):
                sel = a[(a["condition"] == cond) & (a["mode"] == modo)]
                n, media, med, sig, _, _, p90, p95 = resumen(sel["tiempo_s"])
                if n == 0:
                    continue
                target = TARGETS[f"{cond}_{modo}"]
                filas_m.append({"Grupo": cond, "Métrica": "spec_recovery_s", "Modo": modo, "n": n,
                                "μ (s)": fmt(media), "Mediana (s)": fmt(med), "σ (s)": fmt(sig),
                                "P90 (s)": fmt(p90), "P95 (s)": fmt(p95),
                                "Éxito (%)": fmt(sel["exito"].mean() * 100),
                                "Target (s)": fmt(target), "Cumple": "Sí" if p95 <= target else "No"})
    if not argo.empty:
        sel = argo[argo["mode"] == "normal"]
        n, media, med, sig, _, _, p90, p95 = resumen(sel["rto_s"])
        if n:
            target = TARGETS["B_normal"]
            filas_m.append({"Grupo": "B", "Métrica": "rto_s", "Modo": "normal", "n": n,
                            "μ (s)": fmt(media), "Mediana (s)": fmt(med), "σ (s)": fmt(sig),
                            "P90 (s)": fmt(p90), "P95 (s)": fmt(p95),
                            "Éxito (%)": fmt(sel["exito"].mean() * 100),
                            "Target (s)": fmt(target), "Cumple": "Sí" if p90 <= target else "No"})
    if not c_nuevo.empty:
        for modo, target_det, target_rec in (("normal", 30.0, 60.0), ("stress", 30.0, 120.0)):
            sel = c_nuevo[c_nuevo["mode"] == modo]
            if len(sel) == 0:
                continue
            det = pd.to_numeric(sel["tiempo_deteccion_s"], errors="coerce")
            n, media, med, sig, _, _, p90, p95 = resumen(det)
            filas_m.append({"Grupo": "C1", "Métrica": "tiempo_deteccion_s", "Modo": modo, "n": n,
                            "μ (s)": fmt(media), "Mediana (s)": fmt(med), "σ (s)": fmt(sig),
                            "P90 (s)": fmt(p90), "P95 (s)": fmt(p95),
                            "Éxito (%)": fmt(float(sel["degraded_ok"].mean() * 100.0)),
                            "Target (s)": fmt(target_det), "Cumple": "Sí" if p95 <= target_det else "No"})
        for modo, target_det, target_rec in (("normal", 30.0, 60.0), ("stress", 30.0, 120.0)):
            sel = c_nuevo[c_nuevo["mode"] == modo]
            if len(sel) == 0:
                continue
            rec = pd.to_numeric(sel["tiempo_recuperacion_post_revert_s"], errors="coerce")
            n, media, med, sig, _, _, p90, p95 = resumen(rec)
            filas_m.append({"Grupo": "C2", "Métrica": "tiempo_recuperacion_post_revert_s", "Modo": modo, "n": n,
                            "μ (s)": fmt(media), "Mediana (s)": fmt(med), "σ (s)": fmt(sig),
                            "P90 (s)": fmt(p90), "P95 (s)": fmt(p95),
                            "Éxito (%)": fmt(float(sel["recovery_ok"].mean() * 100.0)),
                            "Target (s)": fmt(target_rec), "Cumple": "Sí" if p95 <= target_rec else "No"})
    secciones.append(tabla_md("Tabla 5 — Maestra consolidada (grupos con métrica temporal completa)", cols_m, filas_m))

    contenido = "# Tablas — TFM GitOps/ArgoCD\n\n" + "\n\n".join(secciones) + "\n"
    with open(ruta_md, "w", encoding="utf-8") as f:
        f.write(contenido)
    print(f"  ✓ {os.path.basename(ruta_md)}")


# ══ MAIN ═══════════════════════════════════════════════════════════════════
def main():
    parser = argparse.ArgumentParser(description="Figuras + tablas del TFM GitOps/ArgoCD")
    parser.add_argument("--results-dir", default="results")
    parser.add_argument("--scenario-c-new-csv", default="", help="Ruta opcional CSV escenario C nuevo")
    args = parser.parse_args()

    base = os.path.dirname(os.path.abspath(__file__))
    results_arg = os.path.normpath(args.results_dir)
    if os.path.isabs(results_arg):
        results = results_arg
    elif os.path.exists(results_arg):
        results = os.path.abspath(results_arg)
    else:
        results = os.path.abspath(os.path.join(base, results_arg))
    figuras = os.path.join(base, "figures")
    os.makedirs(figuras, exist_ok=True)

    print(f"[INFO] Cargando CSVs desde: {results}/")
    a, argo, ctrl, c_legacy, c_nuevo = cargar_datos(results)
    if args.scenario_c_new_csv:
        c_legacy, c_nuevo = cargar_datos_c_explicit("", args.scenario_c_new_csv, results)

    print("\n── Escenario A ──")
    fig_hist_A(a, "A1", figuras, 1)
    fig_hist_A(a, "A2", figuras, 2)
    figA3_boxplot(a, figuras)
    figA4_scatter(a, figuras)

    print("\n── Escenario B ──")
    figB1_rto_normal(argo, ctrl, figuras)
    figB2_stress(argo, figuras)
    figB3_comparativa(argo, ctrl, figuras)
    figB4_intervalos(a, argo, figuras)

    print("\n── Escenario C nuevo ──")
    figC1_histograma_deteccion(c_nuevo, figuras)
    figC2_histograma_recuperacion(c_nuevo, figuras)
    figC3_boxplot_normal_vs_stress(c_nuevo, figuras)

    print("\n── Tablas Markdown ──")
    generar_tablas(a, argo, ctrl, c_legacy, c_nuevo, results, os.path.join(figuras, "tablas_tfm.md"))

    print(f"\n✓ Listo. Salida en: {figuras}/")


if __name__ == "__main__":
    main()