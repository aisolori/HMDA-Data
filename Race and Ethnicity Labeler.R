library(arrow)
library(tidyverse)


HMDA_2023<-read_feather("2023_HMDA_ALL_STATES_ORIGINATED_ONLY.feather")

########## Tract Shapefiles ##########
tract_shapefiles <- tracts(cb = TRUE, year = 2023)%>%
  tibble()%>%
  select(GEOID,geometry)
########## County Shapefiles ########
county_shapefiles <- counties(cb = TRUE, year = 2023)%>%
  tibble()%>%
  mutate(area_name = paste0(NAMELSAD, ", ", STUSPS))%>%
  select(GEOID,area_name,geometry)

# HMDA Data Prep
FILTERED_HMDA_2023<-HMDA_2023%>%
  filter(
    # Filtering for purchase transactions
    loan_purpose == 1,
    # Filtering for primary residence
    occupancy_type == 1,
    # Filtering for primary liens
    lien_status == 1,
    # Remove observations with missing income data
    (!is.na(income)) | (income>0) ,
    # Filter for either site built or manufactured homes secured with land
    manufactured_home_secured_property_type %in% c(1,3),
    # Filter for direct ownership of land (applies only to manufactured homes)
    manufactured_home_land_property_interest %in% c(1,5),
    # Filter for single unit homes
    #total_units == 1,
    # Keep only properties not used for commerical purposes
    business_or_commercial_purpose == 2,
    # Remove reverse mortgage
    reverse_mortgage == 2,
    # Remove transactions for open ended line of credit
    open_end_line_of_credit == 2,
    # Keep only fixed rate loans by removing observations with intro rate periods
    # is.na(intro_rate_period),
    # Remove loans with non-amortizing features
    # balloon_payment == 2,
    # interest_only_payment == 2,
    # negative_amortization == 2,
    # other_non_amortizing_features == 2,
    # Remove observations with missing census tract
    !is.na(census_tract)
  )

FILTERED_HMDA_DATA<-FILTERED_HMDA_2023 %>%
  # Aggregation of Disaggregated Race Information
  mutate(
    across(
      .cols = matches("applicant_ethnicity_\\d"),
      .fns = ~{
        # Convert the column to character first
        char_col = as.character(.)
        
        # Apply conditions
        case_when(
          grepl("^1", char_col) ~ "1",
          TRUE ~ char_col
        )
      }
    ),
    derived_ethnicity = case_when(
      is.na(applicant_ethnicity_1) ~"Free Form Text Only",
      applicant_ethnicity_1 %in% c("3","4") ~ "Ethnicity not available",
      TRUE ~ NA_character_)
  )

hispanic_classifier <- function(data){
  # applicant other ethnicities
  applicant_other_ethnicities_blank <- data%>%
    reframe(across(matches("^applicant_ethnicity_[2,3,4,5]"),~ is.na(.x)))%>%
    apply(.,1,function(x) all(x))
  
  applicant_ethnicities <- data%>%
    select(matches("^applicant_ethnicity_\\d"))
  
  applicant_ethnicities_all_hispanic <- apply(applicant_ethnicities,1, function(x) all(x %in% c(NA,"1")))
  applicant_ethnicities_any_hispanic <- apply(applicant_ethnicities,1, function(x) any(x %in% c("1")))
  applicant_ethnicities_any_not_hispanic <- apply(applicant_ethnicities,1, function(x) any(x %in% c("2")))
  
  # Check for all co-applicant races not being in the excluded list
  co_applicant_ethnicities <- select(data, matches("^co_applicant_ethnicity_\\d"))
  no_excluded_co_applicant_ethnicity <- !apply(co_applicant_ethnicities, 1, function(x) any(x %in% "2"))
  co_applicant_ethnicities_none_hispanic <- apply(co_applicant_ethnicities, 1, function(x) all(!x %in% "1"))
  co_applicant_ethnicities_any_not_hispanic <- apply(co_applicant_ethnicities, 1, function(x) any(x %in% "2"))
  co_applicant_ethnicities_any_hispanic <- apply(co_applicant_ethnicities, 1, function(x) any(x %in% "1"))
  
  data <-data%>%
    mutate(derived_ethnicity = case_when(
      applicant_ethnicity_1 %in% "1" &
        applicant_other_ethnicities_blank &
        no_excluded_co_applicant_ethnicity ~ "Hispanic or Latino",
      
      applicant_ethnicities_all_hispanic &
        no_excluded_co_applicant_ethnicity ~ "Hispanic or Latino",
      
      applicant_ethnicity_1 %in% "2" &
        applicant_other_ethnicities_blank &
        co_applicant_ethnicities_none_hispanic ~ "Not Hispanic or Latino",
      
      applicant_ethnicities_any_hispanic &
        co_applicant_ethnicities_any_not_hispanic ~ "Joint",
      
      applicant_ethnicities_any_not_hispanic &
        co_applicant_ethnicities_any_hispanic ~ "Joint",
      
      applicant_ethnicities_any_hispanic &
        applicant_ethnicities_any_not_hispanic ~ "Joint",
      
      co_applicant_ethnicities_any_hispanic &
        co_applicant_ethnicities_any_not_hispanic ~ "Joint",
      
      TRUE ~ derived_ethnicity
    ))
  return(data)
}

FILTERED_HMDA_DATA<-hispanic_classifier(FILTERED_HMDA_DATA)

########## Derived Race ##########

FILTERED_HMDA_DATA<-FILTERED_HMDA_DATA %>%
  # Aggregation of Disaggregated Race Information
  mutate(
    across(
      .cols = matches("applicant_race_\\d"),
      .fns = ~{
        # Convert the column to character first
        char_col = as.character(.)
        
        # Apply conditions
        case_when(
          grepl("^2", char_col) ~ "2",
          grepl("^4", char_col) ~ "4",
          TRUE ~ char_col
        )
      }
    )
  )

minority_race_classifier_1 <- function(data, race_code, race_description, co_applicant_excludes) {
  # Prepare a regex pattern for matching the race code at the start
  race_code_pattern <- paste0("^", race_code)
  
  # Check for all applicant race conditions at once
  only_race_1 <- !is.na(data$applicant_race_1) & data$applicant_race_1 == race_code & 
    is.na(data$applicant_race_2) & is.na(data$applicant_race_3) & 
    is.na(data$applicant_race_4) & is.na(data$applicant_race_5)
  
  # Check for all co-applicant races not being in the excluded list
  co_applicant_races <- select(data, starts_with("co_applicant_race_"))
  no_excluded_co_applicant_race <- !apply(co_applicant_races, 1, function(x) any(x %in% co_applicant_excludes))
  
  # Combine conditions
  valid_race_condition <- only_race_1 & no_excluded_co_applicant_race & is.na(data$derived_race)
  
  # Mutate to create or update the derived_race column
  data <- data %>%
    mutate(derived_race = case_when(
      is.na(applicant_race_1) ~ "Free Form Text Only",
      applicant_race_1 %in% c("6", "7") ~ "Race not available",
      grepl(race_code_pattern, applicant_race_1) & valid_race_condition ~ race_description,
      TRUE ~ derived_race  # Preserve existing values
    ))
  
  return(data)
}

# Initialize the derived_race column with NA if it doesn't already exist
FILTERED_HMDA_DATA$derived_race <- NA_character_

#Example usage for multiple minority groups
FILTERED_HMDA_DATA <- minority_race_classifier_1(FILTERED_HMDA_DATA, "1", "American Indian or Alaska Native", "5")
FILTERED_HMDA_DATA <- minority_race_classifier_1(FILTERED_HMDA_DATA, "2", "Asian", "5")
FILTERED_HMDA_DATA <- minority_race_classifier_1(FILTERED_HMDA_DATA, "3", "Black or African American", "5")
FILTERED_HMDA_DATA <- minority_race_classifier_1(FILTERED_HMDA_DATA, "4", "Native Hawaiian or Other Pacific Islander", "5")

########## Minority Race Classifier 2 ###########
minority_race_classifier_2 <- function(data, race_code, race_description, co_applicant_excludes) {
  # Prepare a regex pattern for matching the race code at the start
  race_code_pattern <- paste0("^", race_code)
  
  # Check for all applicant race conditions at once
  only_race_1 <- !is.na(data$applicant_race_1) & (data$applicant_race_1 %in% c(race_code,"5")) & 
    (data$applicant_race_2 %in% c(race_code,"5")) & is.na(data$applicant_race_3) & 
    is.na(data$applicant_race_4) & is.na(data$applicant_race_5)
  
  # Check for all co-applicant races not being in the excluded list
  co_applicant_races <- select(data, starts_with("co_applicant_race_"))
  no_excluded_co_applicant_race <- !apply(co_applicant_races, 1, function(x) any(x %in% co_applicant_excludes))
  
  # Combine conditions
  valid_race_condition <- only_race_1 & no_excluded_co_applicant_race & is.na(data$derived_race)
  
  # Mutate to create or update the derived_race column
  data <- data %>%
    mutate(derived_race = case_when(
      is.na(applicant_race_1) ~ "Free Form Text Only",
      applicant_race_1 %in% c("6", "7") ~ "Race not available",
      valid_race_condition ~ race_description,
      TRUE ~ derived_race  # Preserve existing values
    ))
  
  return(data)
}

FILTERED_HMDA_DATA <- minority_race_classifier_2(FILTERED_HMDA_DATA, "1", "American Indian or Alaska Native", "5")
FILTERED_HMDA_DATA <- minority_race_classifier_2(FILTERED_HMDA_DATA, "2", "Asian", "5")
FILTERED_HMDA_DATA <- minority_race_classifier_2(FILTERED_HMDA_DATA, "3", "Black or African American", "5")
FILTERED_HMDA_DATA <- minority_race_classifier_2(FILTERED_HMDA_DATA, "4", "Native Hawaiian or Other Pacific Islander", "5")

######### Minorirty Race Classifier 3 ##########
minority_race_classifier_3 <- function(data, race_code, race_description, co_applicant_excludes){
  # Check applicant 1 race
  applicant_races <- select(data, matches("^applicant_race_\\d"))
  # Check if applicant only has race_code,5, or na
  only_race_1 <- apply(applicant_races, 1, function(x) all(x %in% c(race_code,"5",NA)))
  
  # Check coapplicant races
  co_applicant_races <- select(data, starts_with("co_applicant_race_"))
  no_excluded_co_applicant_race <- !apply(co_applicant_races, 1, function(x) any(x %in% co_applicant_excludes))
  
  # Check both conditions
  valid_race_condition <- only_race_1 & no_excluded_co_applicant_race & is.na(data$derived_race)
  
  data <- data %>%
    mutate(derived_race = case_when(
      valid_race_condition ~ race_description,
      TRUE ~ derived_race  # Preserve existing values
    ))
  return(data)
}
FILTERED_HMDA_DATA <- minority_race_classifier_3(FILTERED_HMDA_DATA, "2", "Asian", "5")
FILTERED_HMDA_DATA <- minority_race_classifier_3(FILTERED_HMDA_DATA, "4", "Native Hawaiian or Other Pacific Islander", "5")

########### Two or More Minorities ##########
two_or_more_minorities <- function(data){
  # Check applicant 1 race
  applicant_races <- select(data, matches("^applicant_race_\\d"))%>%
    summarize(num_minority = rowSums(across(everything(),~ .x %in% c("1", "2", "3", "4")), na.rm = TRUE))
  
  # Check coapplicant races
  co_applicant_races <- select(data, starts_with("co_applicant_race_"))
  no_excluded_co_applicant_race <- !apply(co_applicant_races, 1, function(x) any(x %in% "5"))
  
  valid_race_condition <- (applicant_races$num_minority >= 2)& no_excluded_co_applicant_race & is.na(data$derived_race)
  
  data <- data %>%
    mutate(derived_race = case_when(
      valid_race_condition ~ "2 or more minority races",
      TRUE ~ derived_race  # Preserve existing values
    ))
  return(data)
}

FILTERED_HMDA_DATA <- two_or_more_minorities(FILTERED_HMDA_DATA)

########## White Classifier #########
white_classifier <- function(data){
  # Test for applicant_race_1 to see if "5" (white)
  applicant_white <- data$applicant_race_1 %in% "5"
  # Applicant other race fields
  applicant_other_races_blank <- data%>%
    reframe(across(matches("^applicant_race_[2,3,4,5]"),~ is.na(.x)))%>%
    apply(.,1,function(x) all(x))
  
  co_applicant_white <- data$co_applicant_race_1 %in% c("5","6","7","8")
  co_applicant_other_races_blank <- data%>%
    reframe(across(matches("^co_applicant_race_[2,3,4,5]"),~ is.na(.x)))%>%
    apply(.,1,function(x) all(x))
  
  data<- data%>%
    mutate(derived_race = ifelse(
      test = applicant_white & applicant_other_races_blank &
        co_applicant_white & co_applicant_other_races_blank,
      yes = "White",
      no = derived_race
    )
    )
  return(data)
}
FILTERED_HMDA_DATA <- white_classifier(FILTERED_HMDA_DATA)

########## Joint Classifier ##########
joint_classifier <- function(data){
  # Define the list of minority races for easier updates and checks
  minority_races <- c("1", "2",  "3", "4")
  
  # Check applicant races for any minority race
  test_data <- data %>%
    mutate(applicant_minority = rowSums(across(matches("^applicant_race_\\d"), ~ .x %in% minority_races),
                                        na.rm = TRUE) > 0,
           co_applicant_white = rowSums(across(matches("^co_applicant_race_\\d"), ~ .x %in% "5")
                                        , na.rm = TRUE) > 0,
           co_applicant_minority = rowSums(across(matches("co_applicant_race_\\d"), ~ .x %in% minority_races),
                                           na.rm = TRUE)>0,
           applicant_white = applicant_race_1 %in% "5" & is.na(applicant_race_2) & is.na(applicant_race_3) & is.na(applicant_race_4) & is.na(applicant_race_5)
    )
  
  # Apply classification logic based on provided criteria
  data <- data %>%
    mutate(
      derived_race = case_when(
        # If applicant has one or more minority races and any co-applicant race is white
        test_data$applicant_minority & test_data$co_applicant_white & is.na(derived_race) ~ "Joint",
        # If co-applicant has one or more minority races and applicant race 1 is white and other races are blank
        test_data$co_applicant_minority & test_data$applicant_white & is.na(derived_race)  ~ "Joint",
        # Default case if none of the conditions above are met
        TRUE ~ derived_race
      )
    )
  
  return(data)
  
}

FILTERED_HMDA_DATA<- joint_classifier(FILTERED_HMDA_DATA)

# Save FILTERED_HMDA_DATA as feather file
write_feather(FILTERED_HMDA_DATA, "Race & Ethnicity Labeled HMDA Data.feather")
