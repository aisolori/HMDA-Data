## Explanation on Processing Large HMDA LAR Data

This markdown document outlines a workflow for processing large HMDA
Loan Application Register (LAR) data using R. The process involves
reading large text files in chunks, filtering the data based on specific
criteria, and compiling the results efficiently.

2.  **Reading and Processing**: The data is read in chunks using
    `readr::read_delim_chunked`, and each chunk is processed through a
    custom function that filters out rows based on specified criteria.

3.  **Progress Tracking**: A progress bar is implemented to give a
    visual indication of the process completion during the chunk reading
    and processing.

4.  **Result Compilation**: The processed chunks are combined into a
    final dataset. After all chunks are processed, this dataset can be
    saved as a Feather file, which is efficient for storing large
    datasets.

5.  **Libraries**: The required libraries include `arrow` for handling
    large datasets, `dplyr` and `tidyverse` for data manipulation, and
    `progress` to show progress bars.

### **Library Loading**

``` r
library(arrow)
library(dplyr)
library(tidyverse)
library(progress)
library(ggplot2)
library(httr)
library(readr)
```

### **Custom Function**

``` r
# Function to process each chunk 
process_chunk <- function(chunk_df) {
  chunk_df <- chunk_df %>%

    # Filtering for originated loans
    filter(action_taken %in% c(1, "1"))
  return(chunk_df)
}
```

### **Processing of Chunks**
Results will be saved in object `final_results`
``` r
# Initialize final_results
final_results <- data.frame()

# Initialize a progress counter
progress_counter <- 0

# Create a text progress bar object
pb <- txtProgressBar(min = 0, max = 1, style = 3)

# Read the file in chunks
read_delim_chunked(
  file = "2023_combined_mlar_header.txt", # replace this with location of mlar file
  chunk_size = 100000,
  callback = function(chunk, pos) {
    # This part uses the custom function made earlier
    processed_chunk <- process_chunk(chunk)
    final_results <<- rbind(final_results, processed_chunk)
    # Increment the progress counter and update the progress bar
    progress_counter <<- progress_counter + 1
    cat("\rChunks processed:", progress_counter)
    flush.console()
  },
  delim = "|",
  escape_double = FALSE,
  trim_ws = TRUE,
  col_names = TRUE
)
```

#### Save to Feather File if Desired

``` r
# Save Feather File 
write_feather(final_results,"2023_HMDA_ALL_STATES_ORIGINATED_ONLY.feather")
```
