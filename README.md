# Z-FLATE

Aim to create a stdlib replacement for read/write compressed files. Plan to make them single-threaded by default and as the first versions won't include multi-threaded versions... This is due to many of my applications require single-threaded for workflow level parallelization, and don't want o deal with threading issues. 

The stdlib is okay for some compression types however compared to specialized logic like libdeflate for zlib, and ISA-L for gzip is extremely slow. 2-3 times slower... Which is a problem that I have to include those as vendored, not a problem for few projects, but many projects needing would likely require a better on