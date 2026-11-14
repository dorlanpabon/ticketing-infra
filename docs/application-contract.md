# Contrato IaC / aplicaciones

## Persistencia y mensajería

Los roles API y worker de cada microservicio comparten su tabla; ningún otro contexto obtiene acceso. Cada servicio recibe una tabla propia, claves STRING `pk`/`sk`, índices `gsi1(gsi1pk,gsi1sk)` y `gsi2(gsi2pk,gsi2sk)`, proyección ALL y atributo auxiliar `ttl`. TTL es limpieza; no libera reservas de negocio.

SQS Standard configura long polling 20 s, recepción de hasta 10 mensajes desde la aplicación, visibilidad 60 s, retención principal 4 días, DLQ 14 días y `maxReceiveCount=5`. Solo la cola original puede usar su DLQ. La redelivery no autoriza repetir efectos de negocio.

| Worker propietario | Consume | Publica |
|---|---|---|
| catalog | catalog-events | inventory-commands |
| orders | order-events | inventory-commands |
| inventory | inventory-commands, inventory-expirations | inventory-expirations, order-events, catalog-events |

`inventory-expirations` separa los temporizadores del tráfico de reserva/confirmación. Hay cuatro colas principales, cuatro DLQ de consumo y una DLQ adicional para fallos de entrega de Scheduler. El rol Scheduler solo envía a `inventory-expirations` y a su DLQ de entrega; no lee tablas ni consume mensajes.

La transición durable de reserva incluye un outbox `ExpireReservation` con `payload={orderId,expiresAt}`. Al publicarlo, Inventory calcula `DelaySeconds=ceil(expiresAt-now)`, limitado a 0..600, sin reiniciar los diez minutos por reintento. El deadline persistido decide validez; SQS activa el trabajo y no garantiza ejecución exacta en ese segundo.

EventBridge Scheduler envía `SweepExpiredReservations` cada minuto a `inventory-expirations`, ventana flexible OFF, edad máxima de reintento 120 s y dos reintentos. El envelope usa schemaVersion 1, execution-id como messageId/correlationId, scheduled-time como occurredAt y payload vacío. El consumer obtiene un lease durable y cooldown de 60 s antes de consultar los 16 shards del índice de expiración; mensajes duplicados y réplicas no deben multiplicar el barrido. No se invoca una API pública ni Lambda.

## Configuración generada

`terraform output -json app_configuration` produce seis entradas sin credenciales: `catalog-api`, `catalog-worker`, `orders-api`, `orders-worker`, `inventory-api` e `inventory-worker`. La misma configuración alimenta las task definitions. `image_uris` conserva exactamente tres entradas por contexto; ambas tareas de un contexto usan el mismo digest.

| Variables | Contrato |
|---|---|
| APP_ROLE / API_ENABLED / WORKERS_ENABLED | API: api/true/false. Worker: worker/false/true. |
| APP_ENV / SPRING_PROFILES_ACTIVE | dev/qa/prod y perfil aws. |
| AWS_REGION / DYNAMODB_TABLE_NAME | Región y tabla del propietario. |
| INVENTORY_COMMANDS_QUEUE_URL / INVENTORY_EXPIRATIONS_QUEUE_URL / ORDER_EVENTS_QUEUE_URL / CATALOG_EVENTS_QUEUE_URL | URLs derivadas de SQS. Tener una URL no otorga permisos; IAM limita cada rol. |
| INVENTORY_BASE_URL / CATALOG_BASE_URL | DNS privado Cloud Map, puerto 8080. Solo Orders API/worker→Inventory API tiene permiso de red interno inicial. Los workers no se publican en DNS. |
| AUTH_MODE | trusted-gateway; las identidades locales nunca son aceptadas en AWS. |
| RESERVATION_MAX_SECONDS | 600; no se relaja por ambiente. |
| SQS_CONCURRENCY / SQS_WAIT_TIME_SECONDS / SQS_VISIBILITY_TIMEOUT_SECONDS | 16 / 20 / 60. |
| OUTBOX_POLL_INTERVAL_MS / RECONCILIATION_INTERVAL_MS | 500 / 5000. Expiración no usa un cron local cada segundo. |
| MANAGEMENT_* | Readiness habilitado, exposición health/info y sin detalles. |
| LOGGING_STRUCTURED_FORMAT_CONSOLE | ecs; JSON estructurado en stdout. |
| JAVA_TOOL_OPTIONS | Máximo heap 65 %, salida ante OOM y temporales en /tmp. |

El contenedor ejecuta con UID/GID 10001, raíz de solo lectura y temporales únicamente en `/tmp`. La imagen incluye `wget`: ECS comprueba `http://127.0.0.1:8080/actuator/health/readiness` en ambos roles. El ALB comprueba adicionalmente readiness de las APIs. Un worker conserva health en 8080 y rechaza rutas `/api` e `/internal`; su security group no tiene reglas de ingreso.

## Identidad y autorización

API Gateway valida tokens de acceso Cognito: issuer, audiencia y scopes `ticketing/read` o `ticketing/write`. Sobrescribe `X-Authenticated-Subject`, `X-Authenticated-Groups` y `X-Request-Id`. Los valores aportados por el cliente nunca se conservan como autoridad.

La aplicación rechaza sujeto vacío, valida propiedad y exige grupo exacto `admin` para crear eventos y cortesías. Los scopes de escritura no equivalen a rol administrador. `cognito:groups` llega como representación de lista; el parser debe aceptar el formato de Cognito sin buscar subcadenas que permitan confundir `not-admin` con `admin`.

Las nueve rutas públicas son las del contrato `/api/v1`: eventos (crear/listar/obtener), entradas, disponibilidad, órdenes (crear/obtener/confirmar) y cortesías. No existe proxy catch-all público ni ruta `/internal`. Orders API y worker propagan la identidad validada en la consulta privada de Inventory API; las restricciones de security groups impiden otro origen de tareas. Los mensajes no incluyen JWT.

Cognito usa alta administrativa, password fuerte, MFA TOTP y Authorization Code con cliente público/PKCE. No se crean usuarios ni contraseñas en Terraform. Configurar usuarios de prueba mediante el procedimiento autorizado de la cuenta.

## Telemetría

API y worker escriben logs separados por contexto/rol. Solo los workers tienen permisos de consumir/publicar SQS; las APIs guardan intenciones en el outbox de su tabla y no ejecutan polling ni tareas periódicas.

CloudWatch recibe stdout estructurado. Los filtros de métricas de negocio se aplican a los logs de workers y esperan registros JSON de la forma `{"metric":"outbox_age_seconds","value":1.5}` en cada servicio y `{"metric":"expiration_lag_seconds","value":0.4}` en Inventory.

Crear filtros y alarmas no demuestra que la aplicación emita estos registros. Esa integración debe comprobarse con logs reales en la prueba de despliegue; mientras falte evidencia, estos indicadores se consideran configurados y no verificados. Las métricas gestionadas de SQS/API Gateway no dependen de esos logs.
