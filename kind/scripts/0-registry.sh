docker run -d --restart=always \
    -p 127.0.0.1:5001:5000 \
    --network bridge \
    --name kind-registry \
    registry:2.8.3
