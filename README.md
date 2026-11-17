# Infraestructura de la plataforma de venta de entradas

Terraform define la infraestructura de **catalog**, **orders** e **inventory** para DEV, QA y PROD. Cada contexto tiene una API y un consumidor con despliegues independientes. Ambos usan la misma imagen de Amazon ECR, identificada por su digest, y la tabla DynamoDB de su contexto.

Para probar la aplicación con Docker Compose y LocalStack, sigue el `README.md` del repositorio `ticketing-platform`. Los módulos de este repositorio definen **colas Amazon SQS Standard** para AWS. La validación local de Terraform usa un proveedor simulado y comprueba el plan. El despliegue, los permisos efectivos y el rendimiento en AWS requieren una verificación en la cuenta autorizada.

## Estructura

- `infra/bootstrap` configura el estado en S3 con KMS, los tres repositorios ECR y los roles OIDC de GitHub para planificar y aplicar.
- `infra/modules` contiene los módulos de red, datos, mensajería, identidad y entrada, servicios y observabilidad. `platform` los reúne por ambiente.
- `infra/envs/{dev,qa,prod}` define las raíces y los estados de los ambientes.
- `scripts` instala las herramientas verificadas y ejecuta la auditoría por commit.
- `.github/workflows` contiene las comprobaciones de calidad locales y el flujo manual de planificación con un rol de lectura de AWS.

## Herramientas fijadas

| Herramienta | Versión |
|---|---|
| Terraform | 1.17.2 |
| Proveedor AWS de Terraform | 6.73.0, con archivos de bloqueo versionados |
| TFLint | 0.66.0 |
| Checkov | 3.4.5 |
| Gitleaks | 8.30.1 |

Los instaladores de integración continua verifican SHA-256 con los archivos oficiales de cada versión. Terraform verifica los paquetes del proveedor con sus sumas de comprobación. Las versiones de las herramientas y los digests de las imágenes quedan fijados.

## Verificación local

La [guía de verificación](docs/verificacion.md) contiene los comandos de Terraform y Python, los resultados por ambiente y las condiciones para planear en AWS.

## Arquitectura

La [guía de infraestructura](docs/infraestructura.md) explica la red, IAM, el escalado y los costos. Abre el [diagrama con iconos de AWS](docs/diagramas/infraestructura-aws.drawio) mediante **Archivo → Abrir desde → Dispositivo** en [diagrams.net](https://app.diagrams.net/).

## Decisiones y compromisos

| Decisión | Justificación y compromiso |
|---|---|
| Separar API y consumidor | Permite escalar y recuperar el procesamiento de colas sin alterar la capacidad HTTP. Obliga a mantener seis servicios y una capacidad mínima por contexto. |
| Separar tablas y roles | El límite de acceso se aplica por contexto. Las consultas cruzadas se hacen por contrato privado y la consistencia entre contextos depende de mensajes y reconciliación. |
| Cuatro colas principales y temporizadores separados | Aísla la expiración de la carga de reservas y confirmaciones. El plazo persistido sigue siendo la autoridad cuando llegan mensajes duplicados o tardíos. |
| VPC privada con puntos de enlace | Limita la salida de red a los servicios necesarios. Los puntos de enlace de interfaz, el ALB y las tareas mínimas tienen costo aun con poco tráfico. |
| Raíces, estado y cuentas por ambiente | Reduce el alcance de un error de despliegue. Exige preparar por separado la identidad, el estado y la promoción de los digests. |

## Despliegue

Prepara la cuenta, el estado, el presupuesto y los digests indicados en la [guía de verificación](docs/verificacion.md#plan-y-aplicación-en-aws). Un operador autorizado revisa y aplica el plan correspondiente al ambiente. Los planes autenticados se guardan con acceso restringido.
