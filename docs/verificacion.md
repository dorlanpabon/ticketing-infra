# Verificación de infraestructura

Desde la raíz de `ticketing-infra`, usa Terraform 1.17.2, el proveedor AWS fijado en los archivos de bloqueo y Python 3. La primera inicialización necesita acceso al registro del proveedor o a un espejo configurado. Estas pruebas usan `mock_provider` y `command = plan`, con el backend remoto desactivado.

```powershell
terraform fmt -check -recursive infra
if ($LASTEXITCODE -ne 0) { throw 'Hay archivos Terraform sin formato' }
python scripts/test_verify.py
if ($LASTEXITCODE -ne 0) { throw 'Falló la auditoría Git' }

$raices = 'infra/bootstrap', 'infra/envs/dev', 'infra/envs/qa', 'infra/envs/prod'
foreach ($raiz in $raices) {
    terraform "-chdir=$raiz" init -backend=false -input=false -lockfile=readonly
    if ($LASTEXITCODE -ne 0) { throw "Falló init en $raiz" }
    terraform "-chdir=$raiz" validate
    if ($LASTEXITCODE -ne 0) { throw "Falló validate en $raiz" }
    terraform "-chdir=$raiz" test
    if ($LASTEXITCODE -ne 0) { throw "Falló test en $raiz" }
}
```

## Evidencia registrada

El 16 de noviembre de 2026, un clon limpio de `develop` en `80d0252f3989e282b48c5f722e152929e1ae19c8` pasó `init`, `validate` y **14 pruebas simuladas de Terraform** con el proveedor AWS 6.73.0. Pasaron dos en `bootstrap`, cuatro en DEV, cuatro en QA y cuatro en PROD. La auditoría Git pasó **7 pruebas de Python**.

Terraform verificó el aislamiento de ambientes, tareas privadas, reglas de escalado y permisos. Orders API puede enviar a `inventory-commands` mediante `sqs:SendMessage`. Se verificaron cuatro colas principales y cinco DLQ. En una cuenta AWS quedan por comprobar el despliegue y la operación de Fargate, Cognito, IAM/KMS y CloudWatch.

## Plan y aplicación en AWS

`infra-plan.yml` se ejecuta manualmente sobre `develop` para DEV, `release` para QA o `main` para PROD. Configura el ambiente protegido `<env>-plan` y la confianza OIDC del rol de planificación para la cuenta y repositorio correctos. Registra en ese ambiente `AWS_ACCOUNT_ID`, `AWS_PLAN_ROLE_ARN`, `TF_STATE_BUCKET`, `APPROVED_IMAGE_URIS_JSON`, `COGNITO_CALLBACK_URLS_JSON`, `COGNITO_LOGOUT_URLS_JSON`, `ALARM_EMAIL` y `MONTHLY_BUDGET_USD`. El mapa de imágenes usa los tres digests aprobados.

El plan consulta el estado remoto y revisa los cambios propuestos. Conserva el archivo del plan con acceso restringido. Aplicarlo cambia recursos de la cuenta. El operador usa el rol de aplicación y el plan revisado de la misma revisión y ambiente. Mantén las credenciales y los datos sensibles fuera de Git.
