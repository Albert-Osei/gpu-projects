/*
 * Copyright 1993-2015 NVIDIA Corporation.  All rights reserved.
 *
 * Please refer to the NVIDIA end user license agreement (EULA) associated
 * with this source code for terms and conditions that govern your use of
 * this software. Any use, reproduction, disclosure, or distribution of
 * this software and related documentation outside the terms of the EULA
 * is strictly prohibited.
 *
 */
#include "broken_mapped_memory_allocation.h"

__global__ void div(float *d_a, float *d_b, float *d_c, int numElements)
{
    int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < numElements)
    {
        d_c[i] = d_a[i] / d_b[i];
    }
}

__host__ std::tuple<float *, float *> allocateRandomHostMemory(int numElements)
{
    srand(time(0));
    size_t size = numElements * sizeof(float);

    // It is required that mapped memory is used for h_a and h_b
    float *h_a;
    cudaHostAlloc((void **)&h_a, size, cudaHostAllocMapped);

    float *h_b;
    cudaHostAlloc((void **)&h_b, size, cudaHostAllocMapped);

    // Initialize the host input vectors
    for (int i = 0; i < numElements; ++i)
    {
        h_a[i] = LO_RAND + static_cast<float>(rand()) /
                 (static_cast<float>(RAND_MAX / (HI_RAND - LO_RAND)));
        h_b[i] = LO_RAND + static_cast<float>(rand()) /
                 (static_cast<float>(RAND_MAX / (HI_RAND - LO_RAND)));
    }

    return {h_a, h_b};
}

// Based heavily on https://www.gormanalysis.com/blog/reading-and-writing-csv-files-with-cpp/
// Presumes that there is no header in the csv file
__host__ std::tuple<float *, float *, int> readCsv(std::string filename)
{
    vector<int> tempResult;
    // Create an input filestream
    ifstream myFile(filename);

    // Make sure the file is open
    if (!myFile.is_open()) throw runtime_error("Could not open file");

    // Helper vars
    string line, colname;
    float val;

    // Read 1st line of data
    getline(myFile, line);
    // Create a stringstream of the current line
    stringstream ss0(line);

    // Extract each integer
    while (ss0 >> val)
    {
        tempResult.push_back(val);
        if (ss0.peek() == ',') ss0.ignore();
    }

    int numElements = tempResult.size();
    size_t size = numElements * sizeof(float);

    // It is required that mapped memory is used for h_a and h_b
    float *h_a;
    cudaHostAlloc((void **)&h_a, size, cudaHostAllocMapped);

    // Copy all elements of vector to h_a
    copy(tempResult.begin(), tempResult.end(), h_a);
    tempResult.clear();

    // Read 2nd line of data
    getline(myFile, line);
    // Create a stringstream of the current line
    stringstream ss1(line);

    // Extract each integer
    while (ss1 >> val)
    {
        tempResult.push_back(val);
        if (ss1.peek() == ',') ss1.ignore();
    }

    // It is required that mapped memory is used for h_a and h_b
    float *h_b;
    cudaHostAlloc((void **)&h_b, size, cudaHostAllocMapped);

    // Copy all elements of vector to input_a
    copy(tempResult.begin(), tempResult.end(), h_b);

    // Close file
    myFile.close();
    return {h_a, h_b, numElements};
}

__host__ std::tuple<float *, float *> allocateDeviceMemory(int numElements)
{
    // Allocate the device input vector A
    float *d_a = NULL;
    float *d_b = NULL;
    return {d_a, d_b};
}

// NOTE: For mapped memory, cudaHostGetDevicePointer writes the resolved device
// pointer into the LOCAL parameter variable (d_a / d_b are passed by value).
// Those local copies are discarded on return — the caller's d_a and d_b are
// NEVER updated here. This function therefore cannot propagate device pointers
// back to main(). The resolution is done directly in main() instead (see below).
__host__ void copyFromHostToDevice(float *h_a, float *h_b,
                                    float *d_a, float *d_b, int numElements)
{
    // No-op for mapped memory: the GPU accesses h_a/h_b directly through
    // device pointer aliases resolved in main() via cudaHostGetDevicePointer.
    (void)h_a; (void)h_b; (void)d_a; (void)d_b; (void)numElement
}

__host__ void executeKernel(float *d_a, float *d_b, float *h_c,
                             int numElements, int threadsPerBlock)
{
    // Get the GPU side pointer for the mapped h_c buffer
    float *d_c = nullptr;
    cudaError_t err = cudaHostGetDevicePointer((void **)&d_c, (void *)h_c, 0);
    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to get device pointer for h_c (error code %s)!\n",
                cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    // Launch the search CUDA Kernel
    int blocksPerGrid = (numElements + threadsPerBlock - 1) / threadsPerBlock;
    div<<<blocksPerGrid, threadsPerBlock>>>(d_a, d_b, d_c, numElements);

    err = cudaGetLastError();
    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to launch vectorAdd kernel (error code %s)!\n",
                cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    // Synchronize so that h_c is populated before outputToFile reads it
    cudaDeviceSynchronize();
}

// Free device global memory
__host__ void deallocateMemory(float *d_a, float *d_b)
{
    cudaError_t err = cudaFreeHost(d_a);
    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to free device vector d_a (error code %s)!\n",
                cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    err = cudaFreeHost(d_b);
    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to free device vector d_b (error code %s)!\n",
                cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }
}

// Reset the device and exit
__host__ void cleanUpDevice()
{
    cudaError_t err = cudaDeviceReset();
    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to deinitialize the device! error=%s\n",
                cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }
}

// Note that this function should not be modified
__host__ void outputToFile(std::string currentPartId, float *h_a, float *h_b,
                            float *h_c, int numElements)
{
    string outputFileName = "output-" + currentPartId + ".txt";
    // NOTE: Do not remove this output to file statement as it is used to grade assignment,
    // so it should be called by each thread
    ofstream outputFile;
    outputFile.open(outputFileName, ofstream::app);

    outputFile << "PartID: " << currentPartId << "\n";
    outputFile << "Input A: ";
    for (int i = 0; i < numElements; ++i)
        outputFile << h_a[i] << " ";
    outputFile << "\n";
    outputFile << "Input B: ";
    for (int i = 0; i < numElements; ++i)
        outputFile << h_b[i] << " ";
    outputFile << "\n";
    outputFile << "Result: ";
    for (int i = 0; i < numElements; ++i)
        outputFile << h_c[i] << " ";
    outputFile << "\n";

    outputFile.close();
}

// Note that this function should not be modified
__host__ std::tuple<int, std::string, int, std::string, std::string>
parseCommandLineArguments(int argc, char *argv[])
{
    int numElements = 10;
    int threadsPerBlock = 256;
    std::string currentPartId = "test";
    std::string mathematicalOperation = "add";
    std::string inputFilename = "NULL";

    for (int i = 1; i < argc; i++)
    {
        std::string option(argv[i]);
        i++;
        std::string value(argv[i]);
        if (option.compare("-t") == 0)
            threadsPerBlock = atoi(value.c_str());
        else if (option.compare("-n") == 0)
            numElements = atoi(value.c_str());
        else if (option.compare("-f") == 0)
            inputFilename = value;
        else if (option.compare("-p") == 0)
            currentPartId = value;
        else if (option.compare("-o") == 0)
            mathematicalOperation = value;
    }

    return {numElements, currentPartId, threadsPerBlock, inputFilename,
            mathematicalOperation};
}

__host__ std::tuple<float *, float *, int> setUpInput(std::string inputFilename,
                                                       int numElements)
{
    srand(time(0));
    float *h_a;
    float *h_b;

    if (inputFilename.compare("NULL") != 0)
    {
        tuple<float *, float *, int> csvData = readCsv(inputFilename);
        h_a = get<0>(csvData);
        h_b = get<1>(csvData);
        numElements = get<2>(csvData);
    }
    else
    {
        tuple<float *, float *> randomData = allocateRandomHostMemory(numElements);
        h_a = get<0>(randomData);
        h_b = get<1>(randomData);
    }

    return {h_a, h_b, numElements};
}

/*
 * Host main routine
 * -n numElements - the number of elements of random data to create
 * -f inputFile - the file for non-random input data
 * -o mathematicalOperation - this will decide which math operation kernel will be executed
 * -p currentPartId - the Coursera Part ID
 * -t threadsPerBlock - the number of threads to schedule for concurrent processing
 * Note that this function should not be modified
 */
int main(int argc, char *argv[])
{
    auto [numElements, currentPartId, threadsPerBlock, inputFilename,
          mathematicalOperation] = parseCommandLineArguments(argc, argv);

    tuple<float *, float *, int> searchInputTuple =
        setUpInput(inputFilename, numElements);

    float *h_a = get<0>(searchInputTuple);
    float *h_b = get<1>(searchInputTuple);
    numElements = get<2>(searchInputTuple);

    float *h_c;
    cudaHostAlloc((void **)&h_c, numElements * sizeof(float), cudaHostAllocMapped);

    auto [d_a, d_b] = allocateDeviceMemory(numElements);

    // ── THE FIX ────────────────────────────────────────────────────────────
    // copyFromHostToDevice passes d_a/d_b by VALUE so cudaHostGetDevicePointer
    // inside it writes into local copies that are discarded on return.
    // main()'s d_a and d_b stay NULL, causing the kernel to receive NULL
    // input pointers → illegal device memory access.
    //
    // The correct pattern for mapped memory is to resolve the device pointers
    // HERE in main(), where d_a and d_b are the actual variables that will be
    // forwarded to executeKernel(). copyFromHostToDevice is now a no-op.
    cudaError_t err = cudaHostGetDevicePointer((void **)&d_a, (void *)h_a, 0);
    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to get device pointer for h_a (error code %s)!\n",
                cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    err = cudaHostGetDevicePointer((void **)&d_b, (void *)h_b, 0);
    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to get device pointer for h_b (error code %s)!\n",
                cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }
    // ── END OF FIX ─────────────────────────────────────────────────────────

    copyFromHostToDevice(h_a, h_b, d_a, d_b, numElements);  // now a no-op

    executeKernel(d_a, d_b, h_c, numElements, threadsPerBlock);

    outputToFile(currentPartId, h_a, h_b, h_c, numElements);

    deallocateMemory(h_a, h_b);
    cudaFreeHost(h_c);

    cleanUpDevice();
    return 0;
}
