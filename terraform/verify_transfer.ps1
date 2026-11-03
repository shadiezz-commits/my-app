# Runs a one-off Fargate task that compares source vs target and prints the result.
$aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
$r = "eu-north-1"
$net = 'awsvpcConfiguration={subnets=[subnet-0e444c683128b8d21,subnet-02c944fc954f5aa62],securityGroups=[sg-0165d276ea1135345],assignPublicIp=ENABLED}'

$code = @"
import os, re, psycopg2
s = psycopg2.connect(os.environ['SOURCE_DB_DSN']).cursor()
t = psycopg2.connect(os.environ['TARGET_DB_DSN']).cursor()
s.execute('select id, full_name, phone_number, email from legacy_users order by id')
src = s.fetchall()
t.execute('select id, first_name, last_name, phone, email from new_users order by id')
tgt = {r[0]: r for r in t.fetchall()}
print('source rows:', len(src), '| target rows:', len(tgt))
for id_, name, phone, email in src:
    if not name or not name.strip() or not email or '@' not in email:
        print(id_, 'INVALID in source -> expected in dead-letter:', 'NOT in target' if id_ not in tgt else 'WRONGLY in target')
        continue
    parts = name.strip().split(None, 1)
    exp = (id_, parts[0], parts[1] if len(parts) > 1 else '', re.sub(r'\D', '', phone or ''), email)
    print(id_, 'OK' if tgt.get(id_) == exp else 'MISMATCH expected=%s got=%s' % (exp, tgt.get(id_)))
"@

@{ containerOverrides = @(@{ name = "worker"; command = @("python", "-c", $code) }) } |
    ConvertTo-Json -Depth 5 | Set-Content -Encoding ascii ov.json
$arn = & $aws ecs run-task --region $r --cluster etl-worker --launch-type FARGATE --task-definition etl-worker --network-configuration $net --overrides file://ov.json --query "tasks[0].taskArn" --output text
Remove-Item ov.json
& $aws ecs wait tasks-stopped --region $r --cluster etl-worker --tasks $arn
$id = $arn.Split('/')[-1]
& $aws logs get-log-events --region $r --log-group-name /ecs/etl-worker --log-stream-name "worker/worker/$id" --query "events[].message" --output text
