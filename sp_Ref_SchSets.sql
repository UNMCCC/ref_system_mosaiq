USE [MosaiqAdmin]
GO

/****** Object:  StoredProcedure [dbo].[sp_Ref_SchSets]    Script Date: 10/13/2022 4:54:14 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO





CREATE PROCEDURE [dbo].[sp_Ref_SchSets]
	
-- check for valid appointment slips
-- set sequence so that the 1st appt of the day can be easily identified (seq_by_apptTm = 1)
-- BUILT FOR CRIIS DW but has many uses
-- Don't uses Schedule.schStatus_Hist_SD -- it can be set to concatenated values:  ' C,X' for example!
-- Vw_Schedule script picks the TOP 1 from the Schedule Status table -- A REASON TO NOT ALLOW 1 APPT SLIP TO BE RE-USED!
-- To See for yourself TRY THIS: select distinct sch.SchStatus_Hist_SD FROM Mosaiq.dbo.Schedule sch

-- Then get charges associated with each visit
-- Gathers data from both Charge and Charge_Audit 

-- RESULT:  1 row per each Visit (SchSet/Appt Slip)
-- 12/17/21 -- added incremental extract code based on schedule-create-dttm

-- Adds materialized table for CRIIS incremental framework.

AS
BEGIN

SET NOCOUNT ON;

if object_id('tempdb..#Pat_Visits') is not null
	drop table #Pat_Visits;

if object_id('tempdb..#Data') is not null
	drop table #Data;

if object_id('tempdb..#Old') is not null
	drop table #Old;

if object_id('tempdb..#All') is not null
	drop table #ALL;

if object_id('tempdb..#New_IDs') is not null
	drop table #New_IDs;

if object_id('tempdb..#New') is not null
	drop table #New;

select distinct 
	ref.pat_id1, 
	ref.appt_date,
	ref.sch_set_id,				-- Use in RS21/OMOP Visit Details but not in Visit Occurrence
	ref.appt_dtTm,
	ref.activity,				-- do not use in Visit Occurrence
	ref.activity_desc,			-- use activity desc in RS21/OMOP instead of activity
	ref.sch_loc,				-- Use in RS21/OMOP Visit Details but not in Visit Occurrence
	ref.provider_id,			-- Use in RS21/OMOP Visit Details but not in Visit Occurrence
	ref.duration_HrMin,
	ref.schSet_create_dtTm,
	ref.ApptDt_PatID,	      -- This is the breadcrumb used as SOURCE_PK and VISIT_OCCURRENCE_ID in place of a unique
	                          -- key b/c Occurrence identifies the DATE a Patient was seen, not the specific appts
	facility_name,
	facility_id,	
	run_date
into #OLD  -- meaning data existing in the table as of now 
from MosaiqAdmin.dbo.Ref_SchSets ref

select distinct sch.sch_set_id
INTO #ALL
from Mosaiq.dbo.vw_schedule vwS
INNER JOIN Mosaiq.dbo.Schedule sch on vwS.sch_id = sch.sch_id 
INNER JOIN MosaiqAdmin.dbo.Ref_Patients  on sch.pat_id1 = Ref_Patients.pat_id1 and Ref_Patients.is_valid <> 'N' -- eliminate sample patients 
INNER JOIN MosaiqAdmin.dbo.Ref_CPTs_and_Activities on sch.activity = Ref_CPTs_and_Activities.sch_activity_mq  and Ref_CPTs_and_Activities.is_scheduling <> 'N'
where  vwS.Pat_ID1 IS NOT NULL
	and dbo.ufn_isCapturedAppointment(vwS.SysDefStatus) = 'Y'
	and vwS.app_DtTm >= '2010-01-01' -- minimum date 


SELECT A.sch_set_id
into #new_IDs
from (
	select distinct #ALL.sch_set_id, #Old.Sch_Set_ID as Old_Sch_Set_id
	FROM #ALL
	LEFT JOIN #OLD on #ALL.sch_set_id = #OLD.sch_set_id
) as A
where Old_Sch_Set_id is null  -- get new sch-set-id records 


SELECT DISTINCT 
	vwS.Pat_id1,
    Convert(char(10), vwS.App_DtTm, 121)	AS appt_Date,
    sch.SCH_SET_ID,
    vwS.App_DtTm	AS Appt_DtTm,
    vwS.Activity, 
	case 
		when cpt.description is not null and cpt.description <> ' ' then cpt.description 
		when vwS.short_desc is not null and vwS.short_desc <> ' ' then vwS.short_desc
		else vwS.activity
	end activity_desc,
	vwS.location_id as sch_loc,
    vwS.staff_id	AS provider_id,
	mosaiq.dbo.fn_ConvertTimeIntToDurationHrMin(vwS.Duration_time) as duration_HrMin,
	sch.create_dtTm as schSet_Create_DtTm,
	convert(char(8), VwS.app_DtTm, 112) + '-' + cast(vwS.Pat_ID1 as char) apptDt_PatID,
	case 
		when vwS.dept = 'UNMMO' and vwS.location = 'UNM Santa Fe'  then 'UNMCC SF'  -- Santa Fe clinic IDX Facility Names
		when vwS.dept =  'CRTC'  and vwS.activity = 'RadGK'  then 'UNMCC Lovelace MC OP' -- Gamma Knife
		when vwS.dept =  'CRTC'  and vwS.activity <> 'RadGK' then 'UNMCC CRTC'
		else 'UNMCC 1201' 
	end facility_name,	
	case  --FOR CRIIS/OMOP Mapping 5=UNMCC 1201, 77='UNMCC SF', 89='UNMMG Lovelace Medical Center OP',102='UNM CRTC II Radiation Oncology' -- DON'T KNOW HOW TO MAP TO , 51='UNMCC 715'
		when vwS.dept = 'UNMMO' and vwS.location = 'UNM Santa Fe'  then 77  -- Santa Fe clinic IDX Facility Names 77='UNMCC SF'
		when vwS.dept =  'CRTC'  and vwS.activity = 'RadGK'  then 89 --'89='UNMMG Lovelace Medical Center OP' for Gamma Knife
		when vwS.dept =  'CRTC'  and vwS.activity <> 'RadGK' then 102 -- 102='UNM CRTC II Radiation Oncology'
		else 5 -- 5=UNMCC 1201
	end facility_ID,
	GetDate() as run_time
INTO #NEW
FROM Mosaiq.dbo.vw_schedule vwS  -- to get status (sch status is concatenation)
INNER JOIN Mosaiq.dbo.Schedule sch on vwS.sch_id = sch.sch_id   -- to get create_dtT
LEFT JOIN Mosaiq.dbo.CPT on vwS.activity = cpt.hsp_code
INNER JOIN #new_IDs on sch.sch_set_id = #new_IDs.sch_set_id

-- Lets materialize #NEW into the 'incremental' DM for RS21/CRIIS
select distinct 
	#NEW.pat_id1, 
	#NEW.appt_date,
	#NEW.sch_set_id,			-- Use in RS21/OMOP Visit Details but not in Visit Occurrence
	#NEW.appt_dtTm,
	#NEW.activity,			    -- do not use in Visit Occurrence
	#NEW.activity_desc,			-- use activity desc in RS21/OMOP instead of activity
	#NEW.sch_loc,				-- Use in RS21/OMOP Visit Details but not in Visit Occurrence
	#NEW.provider_id,			-- Use in RS21/OMOP Visit Details but not in Visit Occurrence
	#NEW.duration_HrMin,
	#NEW.schSet_create_dtTm,
	#NEW.ApptDt_PatID,			-- This is the breadcrumb used as SOURCE_PK and VISIT_OCCURRENCE_ID as unique key 
	                            -- because Occurrence identifies the DATE a Patient was seen, not the specific appts
	facility_name,
	facility_id,	
	run_time
into #NEW_Pat_Visits
from #NEW -- change to #data when code is removed for SUBSET of patients


TRUNCATE TABLE MosaiqAdmin.dbo.Ref_SchSets_RS21Incremental
INSERT INTO MosaiqAdmin.dbo.Ref_SchSets_RS21Incremental
select 	*
from #NEW_Pat_Visits

SELECT *
INTO #Pat_Visits
From (
	Select *
	from #OLD
	UNION
	SELECT *
	FROM #NEW
) as A
 

select distinct 
	#Pat_Visits.pat_id1, 
	#Pat_Visits.appt_date,
	#Pat_Visits.sch_set_id,				-- Use in RS21/OMOP Visit Details but not in Visit Occurrence
	#Pat_Visits.appt_dtTm,
	#Pat_Visits.activity,				
	#Pat_Visits.activity_desc,				
	#Pat_Visits.sch_loc,					
	#Pat_Visits.provider_id,				
	#Pat_Visits.duration_HrMin,
	#Pat_Visits.schSet_create_dtTm,
	#Pat_Visits.ApptDt_PatID,				
	facility_name,
	facility_id,	
	run_date
into #Data 
from #Pat_Visits -- change to #data when code is removed for SUBSET of patients

TRUNCATE TABLE MosaiqAdmin.dbo.Ref_SchSets
INSERT INTO MosaiqAdmin.dbo.Ref_SchSets
select 	*
from #Data

-- Charges can be joined via sched set 
-- Orders can be joined via pat_id1 and appt-date

END
GO

