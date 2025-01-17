#!/bin/bash

docker buildx build --platform linux/amd64 -t github-runner:latest --load .

# Optional: Run the container if build is successful
if [ $? -eq 0 ]; then
    echo "Build successful! Starting container..."
    docker run -d --name github-runner \
        --env-file .env \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v runner-cache:/home/runner/.cache \
        github-runner:latest
else
    echo "Build failed!"
    exit 1
fi