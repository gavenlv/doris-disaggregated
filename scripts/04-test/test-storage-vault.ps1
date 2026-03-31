# Test Storage Vault Creation via MS API
$MS_URL = "http://doris-disaggregated-ms.doris.svc.cluster.local:5000"
$TOKEN = "greedisgood9999"
$INSTANCE_ID = "doris_instance"

# Get instance info
Write-Host "=== Getting Instance Info ==="
$instanceUrl = "$MS_URL/MetaService/http/get_instance?instance_id=$INSTANCE_ID&token=$TOKEN"
try {
    $response = Invoke-RestMethod -Uri $instanceUrl -Method GET
    Write-Host ($response | ConvertTo-Json -Depth 10)
} catch {
    Write-Host "Error: $_"
}

# Try to add storage vault via MS API
Write-Host "`n=== Trying to add storage vault ==="
$vaultBody = @{
    instance_id = $INSTANCE_ID
    token = $TOKEN
    vault = @{
        name = "minio_vault"
        type = "S3"
        properties = @{
            "s3.endpoint" = "http://minio.doris.svc.cluster.local:9000"
            "s3.region" = "us-east-1"
            "s3.bucket" = "doris"
            "s3.root.path" = "doris"
            "s3.access_key" = "minioadmin"
            "s3.secret_key" = "minioadmin"
            "s3.use_path_style" = "true"
            "s3.enable_ssl" = "false"
        }
    }
} | ConvertTo-Json -Depth 10

Write-Host "Request body:"
Write-Host $vaultBody
