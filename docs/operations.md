# Operación, costos y recuperación

## Señales iniciales

| Señal | Umbral |
|---|---|
| DLQ visible | >0 durante 1 minuto. |
| Edad de mensaje principal | >60 s durante 3 minutos. |
| Outbox | >30 s durante 2 minutos; requiere emisión de la métrica de aplicación. |
| Retraso de liberación | >5 s durante 2 minutos; requiere emisión de Inventory. |
| HTTP 5xx | >5 % durante cinco períodos de 1 minuto. |
| Presupuesto | 80 % real y 100 % previsto del importe autorizado. |

Confirmar la suscripción SNS del destinatario. Una suscripción pendiente no entrega alarmas. Datos faltantes en las alarmas de negocio no se interpretan como error; por eso hay que verificar emisión de métricas, y no considerar un dashboard vacío una señal de salud.

## Escalado independiente

Cada contexto tiene API y worker separados. Las APIs escalan por CPU y nunca consumen colas. Los workers escalan con métricas nativas AWS/SQS: +1 tarea desde 32 mensajes visibles, +2 desde 160, cooldown 60 s. Inventory suma ambas colas, commands y expirations. Scale-in suma visibles e in-flight de todas las colas consumidas: total <1 durante cinco minutos, -1 tarea y cooldown 300 s. Los mensajes retrasados todavía invisibles no escalan; el mínimo siempre activo y el escalado cuando se hacen visibles permiten atenderlos. No depende de ratios de Container Insights ni de una métrica inventada de capacidad.

Estas métricas son aproximadas; el apagado debe detener el polling, respetar el timeout de parada de 60 s y dejar sin ACK cualquier mensaje no confirmado durablemente. La idempotencia, leases y redelivery mantienen corrección. Siempre queda al menos un worker en DEV/QA y dos en PROD para outbox/expiración/reconciliación. No usar autoscaling a cero. Revisar umbrales con tiempo de servicio y carga reales; son parámetros iniciales, no capacidad demostrada.

## Cola caída o consumidor detenido

1. Consultar edad/volumen de SQS, eventos ECS, errores, antigüedad del outbox y salud de DynamoDB.
2. Si SQS falla, preservar el outbox. No generar nuevos IDs ni ampliar deadlines.
3. Corregir permisos, red o imagen del worker afectado; restaurar consumidores con concurrencia limitada sin reiniciar la API. Inventory procesa hasta 10 mensajes por cola en dos loops; Catalog/Orders solicitan lotes de hasta 10. Escalar tareas multiplica la carga potencial sobre sus dependencias.
4. Verificar que baja el backlog y que duplicados no repiten efectos.
5. Confirmar que reservas vencidas se rechazan/liberan aunque el mensaje haya llegado tarde.

## DLQ

Inspeccionar una muestra mediante un operador autorizado; registrar tipo de error e IDs sin publicar datos del comprador. Corregir la causa y ejecutar replay controlado conservando `messageId`, IDs de agregado y versión. No redrive masivo por defecto, no borrar la DLQ para ocultar incidentes y no modificar estados finales. Los task roles no administran redrive.

## Reservas atrasadas

Revisar reloj, outbox, cola inventory-expirations, su DLQ de consumo, permisos de tabla y el lease del barrido. `ExpireReservation` retrasado por SQS es el disparador principal; `SweepExpiredReservations` de Scheduler cada minuto recupera trabajo pendiente. Revisar por separado la DLQ expiry-scheduler: allí falló la entrega de Scheduler a SQS, no el consumer Java.

Scheduler tiene precisión de minuto y SQS entrega al menos una vez; ninguno constituye un reloj exacto de negocio. Inventory valida `expiresAt` en transiciones condicionales aunque el mensaje llegue tarde; no amplía el deadline ni confirma una reserva vencida. La liberación física puede demorarse por backlog/fallo y debe medirse. La recuperación puede añadir hasta el siguiente tick más cola, lease y procesamiento; dos reintentos durante 120 s no eliminan ese límite. Reintentar la transición existente; no editar contadores manualmente ni usar TTL como temporizador. Comprobar `capacity = available + reserved + pendingConfirmation + sold + complimentary` después de recuperación.

## Despliegue fallido

Leer eventos ECS y readiness antes de atribuir el problema al negocio. Comprobar digest existente, arquitectura Linux AMD64, ECR/endpoints, UID, filesystem y variables. Circuit breaker revierte el rollout fallido. Volver a un digest aprobado si es compatible; no restaurar datos como mecanismo de rollback de código.

## Restauración de datos

QA/PROD permiten PITR de DynamoDB. Restaurar a una tabla nueva, aislar escrituras, reconciliar auditoría/órdenes/colas y verificar invariantes antes de conmutar mediante un cambio IaC. La restauración de una tabla no restaura automáticamente las otras tablas ni las colas. Nunca volver a vender entradas SOLD por una restauración parcial.

## Costos

La separación duplica el mínimo de procesos respecto del despliegue combinado: DEV/QA mantienen seis tareas (3 vCPU/6 GiB totales) y PROD doce (6 vCPU/12 GiB), antes de escalar. El máximo configurado de PROD es 36 tareas (18 vCPU/36 GiB); el rolling deployment puede necesitar margen adicional hasta el 200 % por servicio. Verificar cuotas regionales y presupuesto antes de desplegar.

Este sistema no es gratuito en AWS: Fargate, ALB y cuatro interface endpoints en dos zonas generan cargos aun con poco tráfico; también hay KMS, CloudWatch, almacenamiento, transacciones y otras operaciones. El presupuesto cubre la cuenta completa del ambiente y alerta, no detiene gasto. Si se comparte una cuenta, incluirá también sus otros recursos; esta elección conservadora evita depender de la activación tardía de etiquetas de costo. DynamoDB on-demand no elimina límites ni costos de reintentos/transacciones.

El barrido de recuperación genera hasta 43.200 ticks en un mes de 30 días; 16 consultas por tick equivalen a 691.200 Query iniciales antes de paginación/reintentos, más operaciones del lease. El lease global evita multiplicar las consultas por número de workers; adquirir el lease también consume capacidad. Cada reserva añade un temporizador SQS y operaciones de envío/recepción/ACK, outbox e idempotencia; batching, redelivery y tamaño de mensaje cambian el cargo real.

El outbox usa polling adaptativo: activo busca cada 500 ms, inactivo puede esperar hasta 10 s más jitter de 0..250 ms. Un lease de 30 s, renovado con margen de 10 s, limita dispatchers concurrentes, pero no elimina lecturas, renovaciones y contención. Con 16 shards, un dispatcher consultando una vez cada 10 s supone aproximadamente 4.147.200 Query iniciales por mes de 30 días por contexto, antes de jitter y períodos activos. Una intención nueva tras inactividad puede esperar ese backoff antes de publicarse. No se afirma p95 de un segundo universal: medir latencia con tráfico, períodos inactivos y caídas.

Antes de desplegar, estimar costo con AWS Pricing Calculator para región, duración y tareas aprobadas, incluyendo el máximo de autoscaling y el margen del rolling deployment. Conservar el cálculo fechado con el candidato. No se publicó una estimación numérica sin verificar precios y duración reales.

## Desmontaje de demo

Detener pruebas/cargas, conservar evidencia necesaria y revisar un destroy plan en la cuenta/raíz correctas. Buckets no se vacían automáticamente; ECR no borra imágenes mediante force_delete. Limpiar datos solo con autorización y verificando sus rutas/ARN. PROD bloquea eliminación de recursos esenciales y necesita un cambio revisado para levantar esas protecciones.

Revisar recursos residuales: tareas, ALB, endpoints, IP/ENI, logs, namespaces, colas, schedules/groups, tablas, repositorios, buckets, claves pendientes de eliminación y suscripciones. El estado bootstrap tiene `prevent_destroy` y debe conservarse o retirarse mediante un procedimiento separado. No interpretar un `terraform destroy` parcial como eliminación total de costos.
