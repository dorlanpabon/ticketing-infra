# Seguridad y límites

- La entrada pública es HTTPS en API Gateway. VPC Link llega al ALB interno y el ALB solo recibe su security group. Las tareas carecen de IP pública, rutas de Internet y NAT. Solo las tres APIs reciben tráfico del ALB; los workers no tienen ingreso de red. Orders API y worker pueden consultar Inventory API mediante SG específicos.
- En este perfil el salto privado usa HTTP. No se afirma cifrado extremo a extremo ni adecuación regulatoria. TLS e identidad entre workloads son una extensión productiva que exige presupuesto, gestión de certificados y pruebas adicionales.
- Cada task role solo accede a la tabla/índices de su contexto. Solo el rol worker consume sus colas y publica en las colas del contrato; el rol API no tiene permisos SQS. Inventory worker consume tanto commands como expirations. No tiene Scan, permisos de creación de infraestructura ni acceso a tablas ajenas. Execution role y task role están separados.
- ECR login requiere `Resource=*`; lectura de imágenes y logs está limitada a los recursos del servicio. Las claves KMS se rotan, y el acceso de aplicación se restringe a su uso mediante SQS/DynamoDB.
- El rol de plan lee metadatos y estado; no obtiene secretos ni contenidos de tablas/colas. El rol apply es privilegiado para administrar infraestructura y requiere environment protegido. Algunas API de creación/discovery no admiten resource-level authorization. Para IDs aún desconocidos, como Cognito/KMS/API Gateway, el alcance es la cuenta/región; el aislamiento por cuenta y controles organizacionales siguen siendo necesarios.
- Las políticas IAM de bootstrap están divididas para respetar la cuota de 6144 caracteres por managed policy. Su eficacia real no puede probarse con un provider simulado; antes de producción realizar plan autenticado, IAM Access Analyzer y smoke de permisos positivos/negativos.
- No se almacenan secretos en Terraform. Incorporar un servicio que requiera secretos obliga a añadir referencias, permisos mínimos y endpoint Secrets Manager; no se habilita acceso externo genérico.
- Los usuarios se crean fuera de Terraform y MFA es obligatorio. JWT/JWKS se verifica en API Gateway; las tareas no intentan descargar JWKS público desde una VPC sin salida.
- CORS no se habilita por defecto. API Gateway limita frecuencia y ráfagas; la autorización, idempotencia y límites de negocio siguen en las aplicaciones.
- Scheduler asume un rol específico con SourceAccount y ARN exacto del schedule group, como exige [AWS confused-deputy prevention](https://docs.aws.amazon.com/scheduler/latest/UserGuide/cross-service-confused-deputy-prevention.html). Solo puede SendMessage a la cola de expiración y a su DLQ de entrega. La entrada de schedule usa CMK; Decrypt se acota a esa clave y al contexto `aws:scheduler:schedule:arn` del schedule individual, conforme a [AWS encryption at rest](https://docs.aws.amazon.com/scheduler/latest/UserGuide/encryption-rest.html). El uso KMS para las colas tiene un statement separado limitado a ViaService SQS. No se presupone que Scheduler use un forward access session de KMS.

## Excepciones Checkov

Las excepciones están junto al recurso afectado, con razón y revisión el 16 de febrero de 2027. No existe `soft-fail` global ni lista genérica para ocultar errores. La huella de política incluye cada excepción.

| Excepción | Justificación |
|---|---|
| HTTP/redirect/política TLS del ALB | Salto privado explícito; redirigir al cliente a un ALB privado rompería el contrato. |
| Relaciones SG entre módulos / puerto 80 sin CIDR | El grafo estático no resuelve todas las referencias; las reglas usan SG específicos, nunca 0.0.0.0/0. |
| Fargate 1.4.0 frente a LATEST | Versión Linux fijada; revisar actualizaciones antes de cambiarla. |
| PITR en DEV y borrado en DEV/QA | Diferencias deliberadas; QA/PROD protegen recuperación y PROD protege borrado. |
| SSE-S3 del bucket de logs ALB | Requisito de compatibilidad de entrega de logs; datos y estado usan KMS. |
| Notificaciones S3 / replicación / logging recursivo | No son flujos funcionales de la demo; versionado y políticas de acceso permanecen activos. Auditoría corporativa y DR deben definirse para producción. |
| Cognito advanced threat protection | Extensión con costos; ya se exigen MFA, alta administrativa y password fuerte. |
| Resource wildcard en discovery/creación | API sin ARN disponible o sin autorización por recurso; acciones enumeradas y cuentas/roles acotados. |

Cada excepción debe reevaluarse al modificar el recurso o elevar el ambiente a producción. Un scanner verde con excepciones no equivale a ausencia de riesgo.
