# Tablas — TFM GitOps/ArgoCD

### Tabla 1 — Resumen numérico (Escenario A)

| Escenario | Modo | n | μ (s) | Mediana (s) | σ (s) | IC95 lo | IC95 hi | P90 (s) | P95 (s) | Éxito (%) | Target (s) | Cumple |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A — A1 | normal | 30 | 1.27 | 1.00 | 0.45 | 1.10 | 1.43 | 2.00 | 2.00 | 100.00 | 10.00 | Sí |
| A — A1 | stress | 10 | 2.90 | 3.00 | 0.32 | 2.67 | 3.13 | 3.00 | 3.00 | 100.00 | 30.00 | Sí |
| A — A2 | normal | 30 | 1.50 | 1.50 | 0.51 | 1.31 | 1.69 | 2.00 | 2.00 | 100.00 | 5.00 | Sí |
| A — A2 | stress | 10 | 2.80 | 3.00 | 0.42 | 2.50 | 3.10 | 3.00 | 3.00 | 100.00 | 15.00 | Sí |

### Tabla 2 — Estadística descriptiva (Escenario B, ArgoCD normal)

| Escenario | Modo | n | μ (s) | Mediana (s) | σ (s) | IC95 lo | IC95 hi | P90 (s) | P95 (s) | Éxito (%) | Target (s) | Cumple |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| B — ArgoCD | normal | 30 | 9.00 | 9.00 | 0.00 | 9.00 | 9.00 | 9.00 | 9.00 | 100.00 | 30.00 | Sí |

### Tabla 3 — Comparativa ArgoCD vs Control (Escenario B)

| Grupo | n | Tiempo recuperacion obs., medio (s) | Tasa recuperación (%) | Target | Cumple |
| --- | --- | --- | --- | --- | --- |
| ArgoCD — normal | 30 | 9.00 | 100.00 | RTO ≤ 30s | Sí |
| ArgoCD — stress | 10 | TIMEOUT | 0.00 | RTO ≤ 120s (P90) | No |
| Control (sin ArgoCD) | 30 | ∞ (>120s) | 0.00 | Recovery rate = 0% | Sí |

### Tabla 4 — Resumen numérico (Escenario C, rediseñado)

| Escenario | Modo | n | μ (s) | Mediana (s) | σ (s) | IC95 lo | IC95 hi | P90 (s) | P95 (s) | Éxito (%) | Target (s) | Cumple |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| C1 — Detección (push→Degraded) | normal | 30 | 22.90 | 23.00 | 0.48 | 22.72 | 23.08 | 23.00 | 23.55 | 100.00 | 30.00 | Sí |
| C1 — Detección (push→Degraded) | stress | 10 | 23.90 | 24.00 | 0.32 | 23.67 | 24.13 | 24.00 | 24.00 | 100.00 | 30.00 | Sí |
| C2 — Recuperación (revert→Healthy) | normal | 30 | 2.27 | 2.00 | 0.78 | 1.97 | 2.56 | 3.00 | 3.00 | 100.00 | 60.00 | Sí |
| C2 — Recuperación (revert→Healthy) | stress | 10 | 3.80 | 4.00 | 0.63 | 3.35 | 4.25 | 4.10 | 4.55 | 100.00 | 120.00 | Sí |

### Tabla 4b — Tasa de éxito por etapa (Escenario C)

| Modo | n | Degraded detectado | Rollback completado | Pods Ready | HTTP 200×3 | rollback_method |
| --- | --- | --- | --- | --- | --- | --- |
| normal | 30 | 30/30 (100%) | 30/30 (100%) | 30/30 (100%) | 30/30 (100%) | git_revert (100%) |
| stress | 10 | 10/10 (100%) | 10/10 (100%) | 10/10 (100%) | 10/10 (100%) | git_revert (100%) |

### Tabla 4c — Validación cruzada con Prometheus (Escenario C)

| Marca | n | Validadas dentro de margen (±2s) | % | Delta promedio (s) | Nota |
| --- | --- | --- | --- | --- | --- |
| T1 (detección) | 40 | 40/40 | 100.00 | -1.00 | Offset constante = 1 scrape_interval |
| T3 (recuperación) | 40 | 39/40 | 97.50 | -1.00 | 1 excepción: desfase de 2s por fase de muestreo, verificado contra la serie cruda |

### Tabla 5 — Maestra consolidada (grupos con métrica temporal completa)

| Grupo | Métrica | Modo | n | μ (s) | Mediana (s) | σ (s) | P90 (s) | P95 (s) | Éxito (%) | Target (s) | Cumple |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | spec_recovery_s | normal | 30 | 1.27 | 1.00 | 0.45 | 2.00 | 2.00 | 100.00 | 10.00 | Sí |
| A1 | spec_recovery_s | stress | 10 | 2.90 | 3.00 | 0.32 | 3.00 | 3.00 | 100.00 | 30.00 | Sí |
| A2 | spec_recovery_s | normal | 30 | 1.50 | 1.50 | 0.51 | 2.00 | 2.00 | 100.00 | 5.00 | Sí |
| A2 | spec_recovery_s | stress | 10 | 2.80 | 3.00 | 0.42 | 3.00 | 3.00 | 100.00 | 15.00 | Sí |
| B | rto_s | normal | 30 | 9.00 | 9.00 | 0.00 | 9.00 | 9.00 | 100.00 | 30.00 | Sí |
| C1 | tiempo_deteccion_s | normal | 30 | 22.90 | 23.00 | 0.48 | 23.00 | 23.55 | 100.00 | 30.00 | Sí |
| C1 | tiempo_deteccion_s | stress | 10 | 23.90 | 24.00 | 0.32 | 24.00 | 24.00 | 100.00 | 30.00 | Sí |
| C2 | tiempo_recuperacion_post_revert_s | normal | 30 | 2.27 | 2.00 | 0.78 | 3.00 | 3.00 | 100.00 | 60.00 | Sí |
| C2 | tiempo_recuperacion_post_revert_s | stress | 10 | 3.80 | 4.00 | 0.63 | 4.10 | 4.55 | 100.00 | 120.00 | Sí |
