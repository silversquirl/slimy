# Slimy

[![Discord](https://img.shields.io/badge/chat%20on-discord-7289DA?logo=discord)](https://discord.gg/zEnfMVJqe6)

Slimy is a tool to find slime chunk clusters in Minecraft seeds.
It can search on either the CPU or the GPU, and makes use of multithreading to speed up the CPU search.

## Usage

For small searches, I recommend using the [web interface][slimy-web], which will run in your browser.
This is slower than the native binaries, but is much easier to use and can still search a 5000 chunk range in less than 15 seconds.

For large scale searches, use the native version. The latest build can be downloaded [here][builds].
The correct binary for your system is listed below:

- `slimy-x86_64-windows` for Windows systems
- `slimy-x86_64-linux-gnu` for most Linux systems
- `slimy-x86_64-linux-musl` for Linux systems using musl libc - if you need this, you'll know

Once you have the right binary, open a terminal or command prompt in the folder containing it, and run the following command:

```
slimy-SYSTEM -- SEED RANGE THRESHOLD
```

- Replace `slimy-SYSTEM` with the binary name established earlier
- Replace `SEED` with your numeric world seed
- Replace `RANGE` with the number of chunks in each direction you want to search, centered at 0,0. 1000 is a good starting value
- Replace `THRESHOLD` with the minimum number of chunks you want in the despawn sphere. 40 is a good starting value

Once you run the command, it may take a few seconds to complete.
Just wait until it's finished and it'll output the results once it's done.

If you get errors about Vulkan initialization, you can use the CPU search mode like this:

```
slimy-SYSTEM -mcpu -- SEED RANGE THRESHOLD
```

[slimy-web]: https://vktec.org.uk/slimy
[builds]: https://nightly.link/silversquirl/slimy/workflows/build/main/binaries.zip

## System requirements

- CPU search requires an x86_64 CPU and a few megabytes of RAM
- GPU search will work on most Vulkan-capable GPUs

## Advanced usage

For users wanting more control, there are some options that can change how Slimy behaves.

### Output format

By default, Slimy outputs results in a human-readable format.
However, if postprocessing of the results is desired, Slimy can be configured to output them in either CSV or JSON format instead, using the `-f` option.

To output results to a CSV file named `results.csv`, use the following command:

```
slimy-SYSTEM -f csv -- SEED RANGE THRESHOLD >results.csv
```

Similarly, to produce a JSON file named `results.json`, this command can be used:

```
slimy-SYSTEM -f json -- SEED RANGE THRESHOLD >results.json
```

### Unsorted output

If you want to see results more quickly, for example in order to allow further processing to happen in a streaming fashion, you can disable result sorting.
This is done with the `-u` option, as follows:

```
slimy-SYSTEM -u -- SEED RANGE THRESHOLD
```

This option can be combined with the `-f` option to produce unsorted output in a different format, eg. for an unsorted CSV file:

```
slimy-SYSTEM -uf csv -- SEED RANGE THRESHOLD >results.csv
```

### Custom thread count

By default, Slimy's CPU search will use as many CPU threads as are available.
If you wish to customize this behaviour, you can use the `-j` option.
For example, the following command will perform a CPU search with 4 threads:

```
slimy-SYSTEM -m cpu -j 4 -- SEED RANGE THRESHOLD
```
