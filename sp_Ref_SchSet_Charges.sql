USE [MosaiqAdmin]
GO

/****** Object:  StoredProcedure [dbo].[sp_Ref_SchSet_Charges]    Script Date: 10/13/2022 1:38:12 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE PROCEDURE [dbo].[sp_Ref_SchSet_Charges]

/*
Author: Debbie Healy
All Charges for Billable Services
Originally this was built to only extract charges that had a schedule associated with it to meet UNMCCC CRIIS DW requirment
Expanded Aug 2022 to extract all billable charges (see Ref_CPTs_and_Activities for definition of these).
Some charges, such as ECTs are performed at OSIS by our providers.  Schedules are not in MQ but it is still important to capture
these treatments. 
*/
------------------------------------------------------------------------------------------------------------------------------

--Mosaiq.dbo.Charges are linked to Mosaiq.dbo.Schedule via sch_id, which may not the the current tip-record sch_id. 
--So find the sch_set that the charge belongs to

--RESULT:  Multiple Charge rows for each SchSet (Appt Slip)
--drop table #all_chg_ids

/*
THINGS TO REMEMBER: 4/13/2022 DAH
	WHEN WE ARE TALKING CHARGES HERE WE REALLY MEAN PROCEDURES for a PATIENT/DOS 
	CHARGES table doesn't have appt date.  It has procedure_dtTm -- the date component = appt date but proc time and appt time may differ
	SOMETIMES CHARGES do not have the correct SCH_ID assigned or have NO SCH_ID assigned at all
	THE SCH_ID that is captured in CHARGE TABLE will the the id AT TIME TIME THE CHARGE WAS CODE CAPTURED and may not be the latest and greatest sch_id.  
		-- SO ALWAYS USE SCH_SET_ID for comparisons
	Some Charges (such as Interventional Radiation) are entered for procedures performed at other HSC facilities (OSIS...). 
	Since these will not have an associated appt, they won't be used for RS21 (requirement of matching appt dt)
	When a charge is Reviewed the codes are considered to be correct.  However, they can be re-reviewed, but there is no history of a re-review
	8/16/2022 -- added check to be sure the charge has exported -- then we know the codes are correct.  This may cut down on extraneous rows.
*/

AS
BEGIN

if object_id('tempdb..#OldIDs') is not null
	drop table #OLDIDs;

if object_id('tempdb..#Old') is not null
	drop table #OLD;

select *
into #OLD
from MosaiqAdmin.dbo.Ref_SchSet_Charges

select distinct chg_id as Old_Chg_Id
into #OldIDs
from #OLD

select count(*) from #old
/*
-- Select ALL charges; Compare to OLD Charges; only process NEW charges; combine OLD and NEW for deliver
-- Criteria:
--			Charge not voided 
--			Charge has been reviewed
--			Prof or Tech charge (or both) has been extracted (as long as 1 has exported, the coding is correct)
--			Note that data is only as good as it is at the time it leaves Mosaiq.  Errors in coding are changed in the billing systems (IDX/Soarian)
--			So-- True billing data needs to come from those systems
--			However, this is good at linking up the actual RESPONSIBLE provider for technical services 
--				example, the schedule for RO treatments has the name of the technician (or possibly the scheduler) who provided the treatment
--						but the charge has the name of the MD who planned and ordered the treatment.
--				example, the scheduler for MO Infusions has the name of the scheduling template as the provider ("Infusion, 1 hour")
--						but the charge has the name of the MD who ordered the treatment and is responsible for the patient's care.
*/

if object_id('tempdb..#NewIDs') is not null
	drop table #NewIDs;
-- Get list of New Charges (Chg_ID) to collect data on

select A.Chg_id
into #NewIDs
from (
	select 
		chg.chg_id,
		#OldIDs.Old_chg_id as Old_Chg_id
	FROM Mosaiq.dbo.charge chg
	INNER JOIN mosaiqAdmin.dbo.Ref_Patients pat on chg.pat_id1 = pat.pat_id1 and pat.is_valid = 'Y'  -- pull only valid patients
	LEFT JOIN #OldIDs on chg.chg_id = #OldIDs.Old_chg_id
	WHERE chg.reviewed = 1 -- added this per Teri Olson (12/2021) -- until charge has been reviewed and marked for export, codes may change
	and void = 0 -- not voided
	and (chg.Prof_Esi = 1 or chg.Tech_ESI  = 1)  -- 1= 'Exported' ADDED 8/16/2022 DAH - codes won't change after they are exported.
	and chg.proc_DtTm > = '2010-01-01'
	)
	 as A
	where A.Old_Chg_ID is Null

	--1,485,896
	--select top 100 * from #NewIDs
-- ===========================================================================================================================
--	Get the sched_Set_ID, Diagnosis Data, and Rendering Facility (Remember, some procedures are not done at CCC (ex: at OSIS), 
--		but our coders code code the data and charges are entered into Mosaiq)

if object_id('tempdb..#New_Chgs') is not null
	drop table #New_Chgs;
 
SELECT 
	chg.pat_id1, 
	mosaiq.dbo.fn_Date(chg.proc_DtTm) as appt_Date, -- REMEMBER, TIME of procedure may be different than scheduled appointment TIME
	chg.chg_id,
	isNULL(chg.sch_id,0) as chg_sch_id,
	isNULL(ref_SchSets.apptDt_PatID, 0) as apptDt_PatID,
	isNULL(sch.sch_set_id,0) as sch_set_id, -- not all charges will have a sch_id for various reasons
	ref_SchSets.Appt_DtTm,
	ref_SchSets.activity,
	ref_SchSets.sch_loc,
	ref_SchSets.provider_ID as sch_provider_ID,
	chg.prs_id,
	cpts.cpt_code,
	cpts.is_billing,  
	cpts.cpt_desc_mq,
	cpts.proc_name_idx,
	cpts.proc_cat_idx,
	chg.hsp_code, -- set for drugs instead of cpt_code (usually)
	chg.Modifier1,
	chg.Modifier2,
	chg.Modifier3,
	chg.Modifier4,
	chg.days_units,
	chg.Staff_Id as chg_provider_id,
	chg.Rend_FAC_ID,
	fac.name as facility_Name,
	dx1.diag_code as dx1_code,
	dx2.diag_code as dx2_code,
	dx3.diag_code as dx3_code,
	dx4.diag_code as dx4_code,
	chg.tpg_id1,
	chg.tpg_id2,
	chg.tpg_id3,
	chg.tpg_id4,
	chg.create_DtTm as chg_create_dtTm  -- added this per discussion with Inigo, but can't remember why.  Not related to when charges will be sent to RS21. 
into #New_Chgs
FROM Mosaiq.dbo.charge chg
INNER JOIN #NewIDs on chg.chg_id = #NewIDs.chg_id			-- SELECTION CRITERIA FOR CHARGES HANDLED IN #NewIDs Extract above
LEFT JOIN Mosaiq.dbo.schedule sch on chg.sch_id = sch.sch_id -- not all charges will have a sch_id
LEFT JOIN MosaiqAdmin.dbo.Ref_CPTs_and_Activities cpts on chg.prs_id = cpts.prs_id
LEFT JOIN MosaiqAdmin.dbo.ref_SchSets  on sch.Sch_Set_ID = ref_SchSets.Sch_Set_ID
LEFT JOIN mosaiq.dbo.facility fac on chg.rend_fac_id = fac.fac_id
LEFT JOIN mosaiq.dbo.topog dx1 on chg.tpg_id1 = dx1.tpg_id
LEFT JOIN mosaiq.dbo.topog dx2 on chg.tpg_id2 = dx2.tpg_id
LEFT JOIN mosaiq.dbo.topog dx3 on chg.tpg_id3 = dx3.tpg_id
LEFT JOIN mosaiq.dbo.topog dx4 on chg.tpg_id4 = dx4.tpg_id

--select * from #New_chgs where chg_create_dtTm >= '2022-01-01'

-- ===========================================================================================================================
--  Limiting list above to only charges with Billable CPTs

if object_id('tempdb..#New') is not null
	drop table #New;


SELECT
	#New_chgs.pat_id1,			-- may not have sched - so changed to use chg pat id
	#New_chgs.appt_Date,		
	#New_chgs.apptDt_PatID,
	#New_chgs.sch_set_id,		
	#New_chgs.Appt_DtTm,
	#New_chgs.activity,
	#New_chgs.sch_loc,
	#New_chgs.sch_provider_ID,
	#New_chgs.pat_id1 as chg_pat_id, -- pat_id1 above was supposed to be from Ref_SchSets, but now we are including charges that don't always have a sched
	#New_chgs.chg_id,
	#New_chgs.prs_id,			
	#New_chgs.cpt_code,
	#New_chgs.cpt_desc_mq,
	#New_chgs.proc_name_idx,
	#New_chgs.proc_cat_idx,
	#New_chgs.Modifier1,
	#New_chgs.Modifier2,
	#New_chgs.Modifier3,
	#New_chgs.Modifier4,
	#New_chgs.days_units,
	#New_chgs.chg_provider_id,   -- Provider who treated patient or is responsible for treating patient
	#New_chgs.Rend_FAC_ID,		 -- UNMCCC plus other facilities where CCC patients are treated (UH, OSIS...)
	#New_chgs.facility_Name,
	#New_chgs.dx1_code as Diag_code_1,	-- Diagnosis Code
	#New_chgs.dx2_code as Diag_code_2,
	#New_chgs.dx3_code as Diag_code_3,
	#New_chgs.dx4_code as Diag_code_4,
	#New_chgs.tpg_id1,					-- TOPOG (Diagnosis) PK
	#New_chgs.tpg_id2,
	#New_chgs.tpg_id3,
	#New_chgs.tpg_id4,
	#New_chgs.chg_create_dtTm,
	getDate() as run_Date  -- This will represent each batch of charges exported (which is according to export date)
INTO #New
FROM #New_Chgs
where #New_chgs.is_billing = 'Y'  -- RESTRICT TO ONLY BILLABLE CODES (NOT DRUGS, NOT SCHEDULING ACTIVITES...)

--------------------
if object_id('tempdb..#Data') is not null
	drop table #Data;

select distinct *
into #Data
from (
	select *
	from #Old
	union
	select * 
	from #New
	)
as A



TRUNCATE TABLE MosaiqAdmin.dbo.Ref_SchSet_Charges
INSERT INTO MosaiqAdmin.dbo.Ref_SchSet_Charges
select 	*
from #Data
where pat_id1 is not null

TRUNCATE TABLE MosaiqAdmin.dbo.Ref_SchSet_Charges_RS21Incremental
INSERT INTO MosaiqAdmin.dbo.Ref_SchSet_Charges_RS21Incremental
Select *
from #New
where pat_id1 is not null


END
GO

