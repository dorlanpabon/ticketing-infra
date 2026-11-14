# Ambientes, bootstrap y despliegue

## Políticas fijas

| Propiedad | DEV | QA | PROD |
|---|---:|---:|---:|
| Rama autorizada | develop | release | main |
| Tareas mínimas por rol API/worker | 1 | 1 | 2 |
| Tareas máximas por rol API/worker | 2 | 3 | 6 |
| Total mínimo de tareas (tres APIs + tres workers) | 6 | 6 | 12 |
| Total máximo de tareas | 12 | 18 | 36 |
| CPU / memoria por tarea | 0,5 vCPU / 1 GiB | 0,5 vCPU / 1 GiB | 0,5 vCPU / 1 GiB |
| Retención CloudWatch | 7 días | 14 días | 30 días |
| DynamoDB PITR | Desactivado | Activado | Activado |
| Protección de borrado de tablas, ALB y Cognito | Desactivada | Desactivada | Activada |
| CIDR | 10.40.0.0/16 | 10.41.0.0/16 | 10.42.0.0/16 |

Las APIs tienen target tracking de CPU al 60 %. Los workers usan StepScaling sobre SQS: una tarea adicional desde 32 mensajes visibles y dos desde 160, con cooldown de 60 s; bajan una tarea tras cinco minutos sin mensajes visibles ni en vuelo, con cooldown de 300 s. El mínimo nunca es cero, porque outbox y expiración deben permanecer activos. Los límites se aplican a cada uno de los seis despliegues.

La región calificada inicialmente es `us-east-1`. Las raíces fijan dos zone IDs, `use1-az1` y `use1-az2`; se pueden proporcionar otros dos IDs estables de esa región si la cuenta no tiene esas zonas disponibles. El filtro por zone ID evita cambios silenciosos cuando AWS añade zonas.

La organización objetivo usa una cuenta por ambiente. Cada raíz exige el account ID y ARN del rol esperado; el provider limita cuentas y una precondición verifica la sesión STS exacta. Terraform **no vuelve a asumir** el rol recibido por OIDC/AWS_PROFILE. Un usuario IAM directo o una sesión de otro rol no pasa la guarda.

## Bootstrap autorizado

No se ha ejecutado este procedimiento. Antes de hacerlo, definir cuenta, rol de bootstrap, repositorio GitHub real, destinatario de alarmas y presupuesto. Verificar permisos en la landing zone. No guardar credenciales en tfvars.

Las entradas obligatorias de `infra/bootstrap` son `environment`, `expected_account_id`, `bootstrap_role_arn` y `github_repository`. `existing_github_oidc_provider_arn` permite reutilizar el provider de GitHub de una cuenta donde ya exista; no crear un segundo provider con la misma URL.

Autenticar previamente la sesión en el rol autorizado. Establecer las variables `TF_VAR_*` con valores reales o utilizar un archivo de variables fuera de Git. Ejecutar `init`, `plan` y revisar la salida; aplicar exclusivamente ese plan revisado cuando exista autorización. Guardar el estado inicial de bootstrap como información sensible y migrarlo a un backend seguro después de crear el bucket. No mezclarlo con el estado de la plataforma.

El bootstrap crea:

- Bucket de estado cifrado con KMS, versionado, privado y protegido contra destrucción.
- Repositorios ECR `ticketing-<env>/<service>` con tags inmutables y escaneo al publicar. Solo se eliminan imágenes sin tag después de catorce días; los releases etiquetados siguen disponibles para rollback.
- Roles `ticketing-<env>-plan` y `ticketing-<env>-apply`, con confianza OIDC limitada al repositorio real y environments `<env>-plan` / `<env>-apply`.
- El rol de plan puede leer metadatos y estado, y administrar únicamente el objeto de lock; no escribe estado ni lee ítems DynamoDB, mensajes o valores de secretos.

Los outputs incluyen `state_bucket`, `state_kms_key_arn`, `repository_urls`, `plan_role_arn` y `apply_role_arn`. El permiso de publicación ECR pertenece al pipeline de aplicaciones o a un publicador autorizado de la organización; no se concede al rol de plan.

## Variables de plataforma

Cada raíz exige:

| Variable | Contenido |
|---|---|
| `expected_account_id` | Cuenta autorizada de doce dígitos. |
| `assume_role_arn` | Rol ya asumido por el caller; se comprueba contra STS. |
| `image_uris` | Mapa con exactamente catalog/orders/inventory y URI ECR `@sha256`, en cuenta/región aprobadas. |
| `callback_urls`, `logout_urls` | URLs OAuth HTTPS explícitas, sin comodines. |
| `alarm_email` | Destinatario autorizado; confirmar la suscripción SNS. |
| `monthly_budget_usd` | Umbral mensual explícito de alerta; no constituye un límite duro de gasto. |

No hay valores ficticios funcionales en estas variables. Las cuentas e imágenes de `*.tftest.hcl` son fixtures ejecutados únicamente con provider simulado.

Backend: proporcionar el bucket real durante `init`. Cada raíz fija su key `ticketing/<env>/terraform.tfstate`, cifrado y `use_lockfile=true`. No usar workspaces para intercambiar ambientes.

```sh
terraform -chdir=infra/envs/dev init -lockfile=readonly -backend-config="bucket=$TF_STATE_BUCKET"
terraform -chdir=infra/envs/dev plan -out="$APPROVED_PLAN_PATH"
```

El bucket y la ruta del plan son entradas reales del operador, no secretos versionados. El plan contiene configuración potencialmente sensible; almacenarlo con acceso restringido. Escanear su JSON enriquecido con el código Terraform de la revisión exacta para conservar contexto de excepciones.

## CI y GitHub

El repositorio IaC mantiene `main`, `develop`, `release` y ramas feature/fix/chore independientes del repositorio Java. Proteger las ramas y los environments de GitHub antes de habilitar OIDC. Las ramas permitidas por environment son exclusivamente develop→DEV, release→QA y main→PROD.

Tras revisar el primer commit completo de política, configurar `TRUSTED_POLICY_SHA` con ese SHA exacto. El pipeline descarga scripts/configuración de ese commit independiente. `APPROVED_POLICY_HASH` solo se establece para un cambio de política revisado; obtenerlo con `python scripts/verify.py --trusted . --print-policy-hash`. Las exclusiones Checkov y los tests Terraform forman parte de esa huella.

La huella de archivos de política normaliza únicamente CRLF a LF para coincidir entre Windows y Git. Los snapshots del candidato conservan los bytes exactos de cada blob; la auditoría no reescribe contenido ni omite archivos.

La auditoría enumera commits intermedios y merges, materializa blobs exactos de Git y verifica también el resultado integrado. No usa el working tree ni `git archive`, que podría omitir archivos mediante `export-ignore`. Nuevas ramas sin base comprobada recorren toda su historia. Cada SHA obtiene su propio resultado; un gate final no reemplaza el análisis de commits previos.

`infra-plan.yml` es manual. Cada environment `<env>-plan` requiere variables `AWS_ACCOUNT_ID`, `AWS_PLAN_ROLE_ARN`, `TF_STATE_BUCKET`, `COGNITO_CALLBACK_URLS_JSON`, `COGNITO_LOGOUT_URLS_JSON`, `ALARM_EMAIL`, `MONTHLY_BUDGET_USD` y `APPROVED_IMAGE_URIS_JSON`; esta última contiene los tres digests del manifiesto aprobado. Ningún workflow hace apply.

## Promoción y rollback

El manifiesto de aplicaciones debe vincular SHA de apps, SHA de este repo, versiones de contratos y los tres digests. Al copiar imágenes entre cuentas, verificar que el digest se conserva. No reconstruir para QA/PROD ni para el rol worker. Cada digest del manifiesto se utiliza tanto en la API como en el worker de su contexto; solo cambia configuración/IAM/red. La prueba Terraform comprueba esa igualdad.

Después de autorización, el operador usa el rol apply, genera y revisa el plan contra el mismo estado/revisión y aplica exclusivamente el plan aprobado. Confirmar servicios estables, autenticación, rechazo de acceso ajeno, provisioning, reserva, confirmación, expiración, DLQ y alarmas. Esas comprobaciones reales quedan pendientes mientras no exista despliegue AWS.

Rollback cambia a los digests anteriores aprobados y configuración compatible. Nunca restaura una tabla antigua para deshacer una venta ni revierte SOLD/COMPLIMENTARY. Cambios de índices/esquema siguen expand/contract. Un despliegue fallido de ECS activa circuit breaker; la corrección permanente vuelve por fix→develop→release→main.
