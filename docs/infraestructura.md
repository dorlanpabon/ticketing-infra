# Infraestructura de la plataforma de entradas

Terraform define un ambiente AWS para los tres servicios. El [diagrama editable](./diagramas/infraestructura-aws.drawio) muestra la red, las colas y la promoción. Para abrirlo, usa **Archivo → Abrir desde → Dispositivo** en [diagrams.net](https://app.diagrams.net/).

## Red y ejecución

- El cliente entra por HTTPS a API Gateway, que valida los tokens de Cognito y reemplaza los encabezados de identidad. VPC Link envía el tráfico al ALB interno, que distribuye las solicitudes a las tres APIs.
- Catalog, Orders e Inventory tienen una API y un consumidor en ECS con Fargate. Ambas tareas de cada servicio usan el mismo digest de imagen. El ALB y Cloud Map registran las APIs. La API y el consumidor de Orders consultan Inventory API por HTTP privado.
- Las tareas usan dos subredes privadas en zonas distintas, sin IP pública ni NAT. DynamoDB y S3 se alcanzan por puntos de enlace de puerta de enlace. SQS, ECR API, ECR DKR y CloudWatch Logs se alcanzan por puntos de enlace de interfaz.

## Datos, mensajería y seguridad

- Cada servicio usa su tabla DynamoDB y permisos IAM propios. Las escrituras condicionales protegen la asignación de entradas y la idempotencia controla las entregas repetidas de SQS.
- Las cuatro colas SQS Standard son `inventory-commands`, `inventory-expirations`, `order-events` y `catalog-events`. Cada cola tiene una DLQ de consumo. EventBridge Scheduler envía un barrido de recuperación cada minuto y tiene una DLQ separada para fallos de entrega. La expiración normal usa un mensaje diferido y el plazo persistido de la reserva.
- Orders API guarda la intención en el outbox y espera la confirmación de SQS antes del `202`. Su único permiso de SQS es `sqs:SendMessage` sobre `inventory-commands`. Catalog API e Inventory API carecen de permisos de cola. Cada consumidor accede solo a sus colas autorizadas.
- Cognito exige MFA y API Gateway limita frecuencia y ráfagas. La aplicación valida el propietario de la orden y rechaza cambios de contenido para una misma clave de idempotencia. Los roles de ejecución y de tarea están separados. KMS cifra el estado, las tablas, las colas y los grupos de registros. Las credenciales y los secretos se gestionan fuera del repositorio.

## Ambientes y promoción

| Ambiente | Rama y raíz de Terraform | Tareas por rol | Registros | Protección |
|---|---|---:|---:|---|
| DEV | `develop` · `infra/envs/dev` | 1–2 | 7 días | Capacidad inicial para desarrollo |
| QA | `release` · `infra/envs/qa` | 1–3 | 14 días | Recuperación a un punto en el tiempo (PITR) en DynamoDB |
| PROD | `main` · `infra/envs/prod` | 2–6 | 30 días | PITR y protección de borrado en recursos críticos |

Cada ambiente tiene su propia raíz, estado S3, roles y VPC. Las raíces validan la cuenta y el rol esperados. GitHub usa OIDC para el rol de planificación. Un operador autorizado aplica el plan revisado con un rol separado. La promoción conserva los digests de ECR y el manifiesto vincula ambos repositorios con las imágenes aprobadas.

## Operación, costos y límites

Las APIs escalan por CPU y los consumidores por mensajes pendientes en SQS. CloudWatch concentra registros, métricas y alarmas. SNS entrega alarmas a los destinatarios confirmados y AWS Budgets alerta sobre el gasto de cuenta. Las tareas mínimas, el ALB y los puntos de enlace de interfaz generan costos incluso con poco tráfico. También se debe estimar el consumo de DynamoDB, SQS, CloudWatch y KMS.

La verificación local usa planes con un proveedor AWS simulado. El despliegue en AWS, los permisos efectivos, las alertas, la latencia y los costos reales requieren una prueba en la cuenta autorizada. Antes de producción, se deben evaluar TLS e identidad de servicio en los saltos privados, probar la restauración coordinada de datos y ajustar el escalado con carga medida.
