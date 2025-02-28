

#' sparc_medication
#'
#' Finds the medications the participant is prescribed from the
#' electronic medical record and patient reported case report forms at a
#' specific (“index”) date.
#'
#' When the index date is the date of consent, only the patient reported data is used.
#'
#' @param data A list of dataframes, typically generated by a call to load_data. Must include demographics, diagnosis, encounter, procedures, observations, biosample, omics_patient_mapping, and prescriptions.
#' @param index_info A dataframe  with DEIDENTIFIED_MASTER_PATIENT_ID and a variable index_date.  Other options include, enrollment, latest, endoscopy, omics, biosample collection.
#' @param filename the name of the output file. Must be .xlsx.
#'
#' @return A dataframe with medication predictions and an excel file.
#'
#' @details If two medications of the same MOA overlap, the start of the 2nd medication is used as the end date of the previous medication.
#' @export
sparc_medication <- function(data,
                             index_info = c("ENROLLMENT", "LATEST", "ENDOSCOPY", "OMICS", "BIOSAMPLE"),
                             filename = "SPARC_MEDICATION.xlsx") {



  # Get all medication start dates ----

  med <- sparc_med_starts(data$prescriptions, data$demographics, data$observations, data$encounter, export = FALSE)


  # CONSENT INFORMATION ----

  consent <- med %>%
    ungroup() %>%
    distinct(DEIDENTIFIED_MASTER_PATIENT_ID, DATE_OF_CONSENT, DATE_OF_CONSENT_WITHDRAWN)


  # DEMOGRAPHIC INFORMATION ----

  demo <- extract_demo(data$demographics, "SPARC")


  #  DIAGNOSIS & DIAGNOSIS_DATE ----


  dx <- extract_diagnosis(data$diagnosis, data$encounter, data$demographics, "SPARC")



  # CREATE TABLE ----

  table <- consent %>%
    left_join(demo, by = "DEIDENTIFIED_MASTER_PATIENT_ID") %>%
    left_join(dx, by = "DEIDENTIFIED_MASTER_PATIENT_ID")


  # CREATE INDEX_DATE ----

  if ("ENROLLMENT" %in% index_info) {
    cohort <- table %>% mutate(index_date = DATE_OF_CONSENT)
  } else if ("ENDOSCOPY" %in% index_info) {
    endoscopy <- extract_endoscopy(data$procedures)

    cohort <- endoscopy %>% left_join(table)
  } else if ("OMICS" %in% index_info) {
    omics <- data$omics_patient_mapping %>%
      mutate(SAMPLE_COLLECTED_DATE = dmy(SAMPLE_COLLECTED_DATE)) %>%
      mutate(index_date = SAMPLE_COLLECTED_DATE) %>%
      drop_na(index_date) %>%
      select(-c(DATA_SOURCE, DEIDENTIFIED_PATIENT_ID, VISIT_ENCOUNTER_ID)) %>%
      distinct()

    omics_index <- omics %>%
      distinct(DEIDENTIFIED_MASTER_PATIENT_ID, index_date)

    cohort <- omics_index %>% left_join(table)
  } else if ("BIOSAMPLE" %in% index_info) {
    biosample <- data$biosample %>%
      mutate(SAMPLE_COLLECTED_DATE = dmy(`Date Sample Collected`)) %>%
      rename(index_date = SAMPLE_COLLECTED_DATE) %>%
      drop_na(index_date) %>%
      select(-c(DATA_SOURCE, DEIDENTIFIED_PATIENT_ID, VISIT_ENCOUNTER_ID)) %>%
      distinct()


    biosample_index <- biosample %>%
      distinct(DEIDENTIFIED_MASTER_PATIENT_ID, index_date)

    cohort <- biosample %>% left_join(table)
  } else if ("LATEST" %in% index_info) {
    latest <- extract_latest(data$encounter)



    cohort <- table %>% left_join(latest)
  } else {
    cohort <- index_info %>% left_join(table)
  }


  gc()

  # FIND MEDICATION AT INDEX DATE ----

  if ("ENROLLMENT" %in% index_info) {
    cohort <- sparc_medication_enrollment(cohort, med)
  } else {
    # MEDICATIONS AT OTHER INDEX DATES ----

    med_index <- med %>%
      left_join(cohort) %>%
      mutate(int = MED_START_DATE %--% MED_END_DATE) %>%
      rowwise() %>%
      mutate(ON_MED = case_when(
        index_date %within% int ~ 1,
        is.na(MED_END_DATE) & (index_date >= MED_START_DATE) ~ 1,
        TRUE ~ 0
      )) %>%
      ungroup() %>%
      distinct() %>%
      filter(ON_MED == 1) %>%
      group_by(DEIDENTIFIED_MASTER_PATIENT_ID, index_date, MOA) %>%
      slice(which.max(MED_START_DATE)) %>%
      pivot_wider(
        id_cols = c("DEIDENTIFIED_MASTER_PATIENT_ID", "index_date"),
        names_from = ON_MED,
        values_from = c(MEDICATION),
        values_fn = function(x) paste(x, collapse = "; ")
      ) %>%
      rename(MEDICATION_AT_INDEX = `1`)

    cohort <- cohort %>% left_join(med_index)


    med_dates <- med %>%
      left_join(cohort) %>%
      mutate(int = MED_START_DATE %--% MED_END_DATE) %>%
      rowwise() %>%
      mutate(ON_MED = case_when(
        index_date %within% int ~ 1,
        is.na(MED_END_DATE) & (index_date >= MED_START_DATE) ~ 1,
        TRUE ~ 0
      )) %>%
      ungroup() %>%
      distinct() %>%
      filter(ON_MED == 1) %>%
      group_by(DEIDENTIFIED_MASTER_PATIENT_ID, index_date, MOA) %>%
      slice(which.max(MED_START_DATE)) %>%
      pivot_wider(
        id_cols = c("DEIDENTIFIED_MASTER_PATIENT_ID", "index_date"),
        names_from = MEDICATION,
        values_from = c(MED_START_DATE_ECRF, MED_END_DATE_ECRF, MED_START_DATE_EMR, MED_END_DATE_EMR, CURRENT_MEDICATION_ECRF)
      )


    cohort <- cohort %>% left_join(med_dates)


    # Bionaive at omics

    bionaive <- med %>%
      left_join(cohort) %>%
      mutate(int = MED_START_DATE %--% MED_END_DATE) %>%
      rowwise() %>%
      mutate(ON_MED = case_when(
        index_date %within% int ~ 1,
        is.na(MED_END_DATE_ECRF) & (index_date >= MED_START_DATE_ECRF) ~ 1,
        TRUE ~ 0
      )) %>%
      ungroup() %>%
      distinct() %>%
      filter(ON_MED == 1) %>%
      drop_na(BIONAIVE) %>%
      group_by(DEIDENTIFIED_MASTER_PATIENT_ID) %>%
      slice(which.min(BIONAIVE)) %>%
      distinct(DEIDENTIFIED_MASTER_PATIENT_ID, index_date, BIONAIVE) %>%
      ungroup()

    cohort <- cohort %>% left_join(bionaive)

    # NO MEDICATION AT ENROLLMENT

    no_med <- med %>%
      distinct(DEIDENTIFIED_MASTER_PATIENT_ID, NO_CURRENT_IBD_MEDICATION_AT_ENROLLMENT)

    cohort <- cohort %>% left_join(no_med)
  }




  # REORDER COLUMNS & FORMAT SPREADSHEET ----


  bionames <- med_grp %>%
    filter(med_type %in% c("Biologic", "Aminosalicylates", "Immunomodulators")) %>%
    arrange(new_med_name) %>%
    distinct(new_med_name) %>%
    rename(name = new_med_name) %>%
    add_row(name = c("MEDICATION_AT_INDEX")) %>%
    add_row(name = c("NO_CURRENT_IBD_MEDICATION_AT_ENROLLMENT")) %>%
    add_row(name = c("BIONAIVE")) %>%
    arrange(match(name, c("NO_CURRENT_IBD_MEDICATION_AT_ENROLLMENT", "MEDICATION_AT_INDEX", "BIONAIVE")))

  if ("LATEST" %in% index_info) {
    names <- bind_rows(data.frame(name = names(cohort[1:9])), bionames) %>%
      distinct() %>%
      filter(name != "DATE_OF_CONSENT_WITHDRAWN") %>%
      filter(name != "DIAGNOSIS_DATE")
  } else {
    names <- bind_rows(data.frame(name = names(cohort[1:8])), bionames) %>%
      distinct() %>%
      filter(name != "DATE_OF_CONSENT_WITHDRAWN") %>%
      filter(name != "DIAGNOSIS_DATE")
  }

  cohort <- cohort[unlist(lapply(names$name, function(x) grep(x, names(cohort))))]


  names(cohort) <- toupper(names(cohort))

  # FOR OMICS & BIOSAMPLE ADD WHOLE TABLE IN


  if ("OMICS" %in% index_info) {
    cohort <- omics %>% left_join(cohort, by = c("DEIDENTIFIED_MASTER_PATIENT_ID", "index_date" = "INDEX_DATE"))
  } else if ("BIOSAMPLE" %in% index_info) {
    cohort <- biosample %>% left_join(cohort, by = c("DEIDENTIFIED_MASTER_PATIENT_ID", "index_date" = "INDEX_DATE"))
  } else {
    cohort <- cohort
  }

  names(cohort) <- toupper(names(cohort))

  # CREATE HEADER STYLES----

  # orange
  style2 <- createStyle(bgFill = "#F8CBAD", textDecoration = "bold")


  # CREATE WORKBOOK ----

  wb <- createWorkbook()
  addWorksheet(wb, "med_at_index")
  writeData(wb, "med_at_index", x = cohort, startCol = 1, startRow = 1, colNames = TRUE, rowNames = FALSE)


  # FORMAT CELLS ----


  democoln <- max(which(colnames(cohort) %in% c("DIAGNOSIS")))

  rown <- dim(cohort)[1]
  coln <- dim(cohort)[2]

  conf <- max(which(colnames(cohort) %in% toupper("MEDICATION_AT_INDEX")))

  # column headers
  conditionalFormatting(wb, "med_at_index", cols = 1:democoln, rows = 1, rule = "!=0", style = style2)
  conditionalFormatting(wb, "med_at_index", cols = (democoln + 1):conf, rows = 1, rule = "!=0", style = style2)
  conditionalFormatting(wb, "med_at_index", cols = (conf + 1):coln, rows = 1, rule = "!=0", style = style2)



  # SAVE REPORT ----

  saveWorkbook(wb, file = paste0(filename), overwrite = TRUE)

  return(cohort)
}
