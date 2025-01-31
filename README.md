
# docker

## build

```
docker buildx build --load --tag ai .
```

## run

```
docker run -v ai:/ai -v ~/.airc:/ai/.airc --rm -it ai
```
