# aelm
Adequate Environment &amp; Language Manager

## How
Download [a release](https://github.com/JorySchossau/aelm/releases) and run from anywhere.

Download an environment
```sh
./aelm add python myLocalPython
```
Run a command in that environment
```sh
./aelm exec myLocalPython python --version
```
Or activate like a virtual environment
```sh
source myLocalPython/activate
source myLocalPython/deactivate
```
Or install globally for your user
```sh
./aelm add python --user
```

## Why
To:
* Automate software configuration and environments
* Work without root/admin
* Work on Windows, Linux, Mac, aarhc64Lnux, M1Mac
* Replace docker for HPC environments
