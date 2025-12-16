# poc-hynix

## 1. docker network 생성

```bash
docker network create n8n-network
```

## 2. docker 파일 합치기
```bash
cat n8n.1.113.3.tar.part.* > n8n.1.113.3.tar
cat opmate-api.v0.1.tar.part.* > opmate-api.v0.1.tar
cat postgres.16.tar.part.* > postgres.16.tar
cat qdrant.v1.15.1.tar.part.* > qdrant.v1.15.1.tar
```

## 3. docker 이미지 로드
```bash
docker load -i n8n.1.113.3.tar
docker load -i opmate-api.v0.1.tar
docker load -i postgres.16.tar
docker load -i qdrant.v1.15.1.tar
```

## 4. docker-compose로 설치
```bash
docker-compose -f docker-compose.n8n.yml        up -d
docker-compose -f docker-compose.postgres.yml   up -d
docker-compose -f docker-compose.qdrant.yml     up -d

# opmate-api는 opmate endpoint랑 key, secret값 업데이트 후 설치
docker-compose -f docker-compose.opmate-api.yml up -d
```

## 5. n8n 추가 패키지 설치 # PSM 251215 NW용
```bash
# n8n 컨테이너에 패키지 복사
docker cp ./os-package n8n:/tmp/

# n8n 컨테이너에서 패키지 설치
docker exec -u root n8n sh -c "apk add --no-network --allow-untrusted /tmp/os-package/*.apk"

# 설치 확인
docker exec n8n sh -c "sshpass -V && snmpwalk --version && expect -v"
```