# Evidencia local de infraestructura

Fecha: 16 de noviembre de 2026. Ejecución sobre el working tree anterior al commit inicial de este repositorio. Los próximos commits deben conservar su evidencia por SHA mediante el pipeline; este informe no se presenta como un resultado GitHub Actions ni como validación AWS.

| Verificación ejecutada | Resultado |
|---|---|
| Terraform 1.17.2 `fmt -check -recursive` | Correcto. |
| `validate` con AWS provider 6.73.0 | Correcto en bootstrap, DEV, QA y PROD, sin warnings. |
| Tests Terraform con `command=plan` y `mock_provider` | 14 runs correctos: bootstrap 2; DEV, QA y PROD 4 cada uno. |
| TFLint 0.66.0 recursivo | Cero hallazgos. |
| Checkov 3.4.5 Terraform | 384 controles correctos sobre 214 recursos; cero fallidos; 57 instancias de excepciones documentadas; cero errores de parsing. |
| Checkov 3.4.5 GitHub Actions | 68 controles correctos; cero fallidos; cero excepciones. |
| Gitleaks 8.30.1 con redacción y política explícita | Sin filtraciones detectadas. |
| Tests de auditoría Git | 6 correctos: commits intermedios, historia nueva, snapshot exacto, export-ignore y frontera de política. |

Los tests verifican seis roles privados/no root/raíz de solo lectura; misma imagen por contexto; ausencia de SQS en APIs y de ALB/DNS en workers; escalado por ambiente y suma de ambas colas Inventory; PITR y protección de tablas; ALB interno y nueve rutas JWT; límites IAM, rol/cuenta, digests y callbacks seguros. Comprueban cuatro colas principales, cinco DLQ, Scheduler cada minuto a la cola de expiración, confianza por cuenta/schedule-group y retry acotado. Los datos de prueba no se enviaron a AWS.

No se ejecutaron `terraform apply`, despliegues, creación de usuarios, envío de notificaciones ni pruebas reales de cuentas AWS. Tampoco se probó el arranque Fargate, el flujo Cognito/API Gateway, los permisos efectivos de bootstrap/Scheduler/KMS, la entrega de alertas o las métricas de aplicación en CloudWatch. Esos controles están definidos en los runbooks y requieren una ejecución cloud autorizada.
