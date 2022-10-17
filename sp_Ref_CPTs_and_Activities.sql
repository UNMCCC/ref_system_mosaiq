USE [MosaiqAdmin]
GO

/****** Object:  StoredProcedure [dbo].[sp_Ref_CPTs_and_Activities]    Script Date: 10/13/2022 1:53:11 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO





CREATE PROCEDURE [dbo].[sp_Ref_CPTs_and_Activities]
/*** 
*	PURPOSE ******************************************************************
*	To categorize ALL CPT,HCPCS, & Activites from Mosaiq.dbo.CPT table 
*	for use in CRIIS dw tables and other visit-reporting.
*	Categories: administrative, scheduling, billing, drug.  
*	Codes may be in more than 1 category.
*
*	DESCRIPTION **************************************************************
*	Categorize Mosaiq Activites and CPTS according to use (may have multiple
*   uses.  Combines fields from Mosaiq and MG IDX DW. Billing CPTS identified
*	from IDX dw.
*	
*	COMMENTS *****************************************************************
*	Differs from visit-system objects in that ALL codes are extracted,
*	not just those used on scheduled visits (2014-onward)
*	Must be maintained with addition of new scheduling activities.
*	TIMING -- Must run AFTER dbo.sp_Ref_Patient_Drugs_Administered because it relies
*       on administered drugs to classify J-code HCPCS (drugs)
****************************************************************************/


AS
BEGIN

if object_id('tempdb..#MQ_CPT_All') is not null
	drop table #MQ_CPT_All;

if object_id('tempdb..#MQ_CPT') is not null
	drop table #MQ_CPT;

if object_id('tempdb..#billing') is not null
	drop table #billing;

if object_id('tempdb..#HCPCS') is not null
	drop table #HCPCS;

if object_id('tempdb..#Scheduling_Activities') is not null
	drop table #Scheduling_Activities;

if object_id('tempdb..#Observation_orders') is not null
	drop table #Observation_orders;

if object_id('tempdb..#IDX_Match') is not null
	drop table #IDX_Match;

if object_id('tempdb..#MQ_CPT_Classified') is not null
	drop table #MQ_CPT_Classified;



-- ===================================================================================================================================================
------------------------DEFINITIONS-------------------------------------------------------------------------------------------------
-- https://www.medicalbillingandcoding.org/hcpcs-codes/

-- Healthcare Common Procedure Coding System (HCPCS), commonly pronounced “hicks-picks. 
-- HCPCS identify WHAT A PROVIDER USES (drugs, devices, etc)

-- When we talk about HCPCS, we are referring to the alphanumeric codes that begin with a letter. Technically these are Level II HCPCS.
-- The letter(generally) indicates the type. 
-- J-codes, for example, are the codes for non-orally administered medication and chemotherapy drugs. 
--
-- https://www.medicalbillingandcoding.org/intro-to-cpt/
-- Current Procedural Terminology (CPT)
-- CPT CODES identify what a PROVIDER DOES (exams, surgery, treatment planning, administering a drug, etc)

-- Category I CPT CODEs describes procedures, services, and technologies administered by healthcare professionals.
-- Evaluation and Management: 99201 – 99499
-- Anesthesia: 00100 – 01999; 99100 – 99140
-- Surgery: 10021 – 69990
-- Radiology: 70010 – 79999
-- Pathology and Laboratory: 80047 – 89398
-- Medicine: 90281 – 99199; 99500 – 99607
-- Category II codes provide additional info.  They are alpha codes with 4 digits ending in 'F'.
-- Category III are temporary codes.
-- ===================================================================================================================================================
-- PRACTICALLY SPEAKING
-- I've tried lots of methods to categorize codes based on fields available to us and nothing is perfect.  
-- Fields in Mosaiq.dbo.cpt that should help are not consistently set correctly (including billable, cgroup, code_type, supply_type, drg_id)

-- SUGGESTION: work with MQ APPS clean up billable, code_type, and supply_type so that they could be reliable and add codes here ...

-- A more ambitious project would be to fix CGROUP -- I've tried and it's massive.  But I think this is field Elekta intended for classifiation.
--
-- Resist excluding "deleted" or "inactive" codes.  These may have been retired by the Medical Coders but have been used in the past.
--
-- IN Mosaiq the CPT table is used for true CPT codes, HCPCS, and user-defined scheduling and ordering and administrative codes.
-- The CPT_Code field will contain true CPTs, HCPCs, and user-defined categories for scheduling and ordering codes ('np', 'ov', etc)
-- The CPT Code field may be blank, especially for drugs.  Drugs are usually in the HSP_Code field ("hospital code").
-- CPT.hsp_code = Schedule.activity
-- Drug codes don't always have a drg_id (Drug table FK)
-- Some HSP_Codes have the modifier appended to the CPT_Code ('76000 TC','76000 26','J9035 JW')
-- The Primary Key for Mosaiq.dbo.CPT is prs_id.  There may be multiple prs_ids with the same cpt_code -- so be careful.
-- It's a mess of a table
--
-- IDX dss.proc_dim contains CPT Codes, HCPCS, Administrative codes (6-digit internally defined or alpha; see exclusion list below).
-- IDX calls the codes procedure (proc) codes.  The UH team (Michelle) usually refers to "proc Codes" instead of CPT.
-- Classification fields in IDX are also not set consistently, although I have included them here as extra info, but don't count on them.


-- ===================================================================================================================================================
-- Let's start by pulling all CPT codes and identifying Administrative codes. 
-- Identifying Admin codes is done by brute force and may not be all-inclusive.
-- These include appts with financial counselers and Medical Records; activites for provider comments, and to block off schedules. 
-- Also included are "Invalid" CPT Codes, such as those starting with 'X'.
---- Fun fact:  "No Bill" is actually a schedulable RO event.  David Hopper named it because it is an appt that is not billed
----             However,"No Bill" is not counted in visits because it was never include due to lack of clarity as to its purpose
-- ===================================================================================================================================================

select
	prs_id,
	cpt_code,
	hsp_code,
	isNULL(drg_id, ' ') as drg_id,
	description
Into #MQ_CPT_ALL
from Mosaiq.dbo.CPT


select 	
	prs_id,
	cpt_code,
	hsp_code,
	isNULL(drg_id, ' ') as drg_id,
	description,
	'Y' as is_Administrative
into #Administrative
from #MQ_CPT_ALL    -- found these by brute force; there are probably MORE
Where  (hsp_code in ('000', '1 NOTE 2','EDUTIMEOF', 'Interpret',  'Finan Asst', 'Financial', 'FinCon',  'LUNCH') 
		  or hsp_code in ('MACH MAINT', 'MEDRC', 'Meeting', 'MESSAGE',  'No Bill', 'No F/U', 'None', 'NOTE', 'LOBBY')
		  or hsp_code in ('ObtainMR',  'ON Call', 'PHYSICS' , 'PRIV CONF','RO PHYSICS',  'RESEARCH', 'ROUNDS')		 
	      or hsp_code in ('See Note', 'STAFFMTG', 'TEMP APPT', 'TUMBORD', 'UPDATE', 'VACATION', 'ZZZCF', 'Navigator','CkLabs')
		  or hsp_code in ('NApptN','NoApptN','No Contras', 'NoLN', 'NKA Contr','CHART R', 'CLINIC', 'OFF SITE', 'PRPMT', 'ROUNDS', 'MED RCD', 'Unkn 10849')
		  or hsp_code in ('BCC CHG', 'xx', 'MISYSBAL', 'PREPY', '999020') -- in IDX also as Administrative codes
		)
	or (prs_id = 10891 -- 'hsp_code = '----------------'
		  or prs_id = 13797 -- 'test'
		  )

	or  (Cpt_code = ' ' and left(hsp_Code,1) = 'X')  -- these appear to be "deleted" codes
	or  cpt_code = 'x'
	or  left(cpt_code,3) = 'X99'  -- invalid CPTs
	or  cpt_code in ('Admin', 'FC', 'MedRecords')

-- ===================================================================================================================================================
-- Let's reduce table by known administrative (or incorrect) codes to simplify the rest of the categorizing
-- drop table #MQ_CPT
select
	#MQ_CPT_ALL.prs_id,
	#MQ_CPT_ALL.hsp_code,   
	#MQ_CPT_ALL.cpt_code,
	#MQ_CPT_ALL.drg_id,
	#MQ_CPT_ALL.description
into #MQ_CPT         -- Use this for the rest of the categorizations
from #MQ_CPT_ALL
left join #Administrative on #MQ_CPT_ALL.prs_id = #Administrative.prs_id
where #Administrative.prs_id is null

	select 
	#MQ_CPT.prs_id,
	#MQ_CPT.hsp_code,   
	#MQ_CPT.cpt_code,
	#MQ_CPT.drg_id,
	#MQ_CPT.description,
	IDX.proc_cd   as proc_cd_IDX,				 -- cleaner than Mosaiq CPT.CPT_code
	IDX.proc_name as proc_name_idx,			 -- included for extra info; 
	IDX.proc_cat_name  as proc_cat_Idx,		 -- included for extra info; don't rely on for filtering; incomplete categorization
	IDX.proc_unmmg_cat as proc_unmmg_cat_IDX, -- included for extra info; don't rely on for filtering; incomplete categorization
  	IDX.proc_key  as proc_key_IDX
	into #Billing
	from #MQ_CPT
	inner join [MGBBRPSQLDBS1\UNMMGSQLDWPROD].unmmgdss.dss.proc_dim IDX on left(#MQ_CPT.cpt_code,5) = IDX.proc_Cd  --join on CPT
	where left(IDX.proc_cd, 1) in ('0','1','2','3','4','5','6','7','8','9')   

select distinct 
		B.prs_id,
		B.hsp_code,  --  hsp_code is set for DRUGS, not (ususally) cpt
		B.cpt_code,
		B.drg_id,
		B.description,
	IDX.proc_cd  as proc_cd_IDX,			 -- cleaner than Mosaiq CPT.CPT_code
	IDX.proc_name as proc_name_idx,			 -- included for extra info; 
	IDX.proc_cat_name as proc_cat_Idx,		 -- included for extra info; don't rely on for filtering; incomplete categorization
	IDX.proc_unmmg_cat as proc_unmmg_cat_IDX, -- included for extra info; don't rely on for filtering; incomplete categorization
	IDX.proc_key as proc_key_IDX
into #HCPCS
from (
	select distinct   -- get distinct list from the UNIONs
			A.prs_id,
			A.hsp_code,  --  hsp_code is set for DRUGS, not (ususally) cpt
			A.cpt_code,
			A.drg_id,
			A.description
	from (	
			select
				#MQ_CPT.prs_id,
				#MQ_CPT.hsp_code,  --  hsp_code is set for DRUGS, not (ususally) cpt
				#MQ_CPT.cpt_code,
				#MQ_CPT.drg_id,
				#MQ_CPT.description
			from #MQ_CPT
			inner join [MGBBRPSQLDBS1\UNMMGSQLDWPROD].unmmgdss.dss.proc_dim IDX on left(#MQ_CPT.hsp_code,5) = IDX.proc_Cd  -- Join on the hsp_CODE 
			where left(IDX.proc_cd,1)  in ('A','C','G','J','P','Q','S')   -- use IDX field to avoid MQ activite codes
				   and IDX.proc_cd <> '?'

			-- Left 5 digit command used for same reason as with billing codes 
			UNION
				select 
				#MQ_CPT.prs_id,
				#MQ_CPT.hsp_code,  --  hsp_code SHOULD be used for drugs, not cpt
				#MQ_CPT.cpt_code,
				#MQ_CPT.drg_id,
				#MQ_CPT.description
	
				from #MQ_CPT
				where right(#MQ_CPT.hsp_code, 2) = 'JW'  -- this will find ones with the drug-waste modifier added (JW)
				) as A
				) as B
LEFT join [MGBBRPSQLDBS1\UNMMGSQLDWPROD].unmmgdss.dss.proc_dim IDX on left(B.hsp_code,5) = IDX.proc_Cd  -- Now, rejoin on hsp_code to get IDX data
		 and left(IDX.proc_cd,1)  in ('A','C','G','J','P','Q','S')   -- use IDX field to avoid MQ activity codes
 
-- ================================================================================================================================
------------------------- SCHEDULING ACTIVITY CODES -------------------------------------------------------------------------------

----- ACTIVITY and CPT CODES Used in Scheduling Appointments ---NOTE CODES MAY BE USED IN ORDERING and BILLING! YIKES MOSAIQ!-------
----- Technically, MO is supposed to use "activity" codes for scheduling, not billing codes..., but both activity and billing codes get used
----- RO uses billing codes for scheduling (although those may not be the codes actually billed after coding does their thing.  
------Usually, activity codes are used by RO
------Even Drugs have been scheduled --UGH! What does that mean? -----So Let's gather codes used in scheduling without judgement
------IDX proc-codes have already been found for any activity codes that are true CPT or HCPCS 


SELECT DISTINCT		
	prs_id,
	cpt_code,	 -- USED as classification for Non-Billing and Non-HCPCS codes
	hsp_code,    -- CPT.hsp_code = SCHEDULE.Activity
	drg_id,
	description
into #Scheduling_Activities
FROM (
	select DISTINCT					-- get all activity codes used in scheduling; 
		#MQ_CPT.prs_id,
		#MQ_CPT.cpt_code,
		vwS.activity as hsp_code,
		#MQ_CPT.drg_id,
		#MQ_CPT.description
	from Mosaiq.dbo.vw_Schedule vwS			
	inner join #MQ_CPT on vwS.activity = #MQ_CPT.Hsp_Code
UNION
	select DISTINCT -- this will get activities that are correctly categorized, but not yet scheduled, such as new providers
		prs_id,
		cpt_code,
		hsp_code,
		drg_id,
		description
	from #MQ_CPT
	where cpt_code in ('gc','gk','gkTx_LL','ir','np','ov','pc','po','pr','psy','PsyIntern','Ptcl RN V','RN','SupTh','tv','Nurse','Nutrition')
	   or cpt_code in ('Admin','FC','InfSuite','MedRecords','ObtainMR','ShotCl','Bone M Bx', 'GastroEnem', 'Sim')
) as A

-- ================================================================================================================================
------------------------- ORDERING ACTIVITY CODES -------------------------------------------------------------------------------
--- GET OBSERVATION ORDERS -- These are orders placed by activity codes for appointments, lab tests, evaluations, scans, referrals
--- Don't confuse these with In-House Pharmacy Orders (Order_Type = 4)
--- MOST orders will be in-house activity type codes (similar to scheduling codes), but some will use true CPT
--- 

SELECT	Distinct
	obr.prs_id,
	cpt.cpt_code,
	cpt.hsp_code,
	cpt.drg_ID,
	cpt.description,
	IDX.proc_cd  as proc_cd_IDX,			 -- cleaner than Mosaiq CPT.CPT_code
	IDX.proc_name as proc_name_idx,			 -- included for extra info; 
	IDX.proc_cat_name as proc_cat_Idx,		 -- included for extra info; don't rely on for filtering; incomplete categorization
	IDX.proc_unmmg_cat as proc_unmmg_cat_IDX, -- included for extra info; don't rely on for filtering; incomplete categorization
	IDX.proc_key as proc_key_IDX
into #Observation_orders
FROM MOSAIQ.dbo.ObsReq obr 
INNER JOIN MOSAIQ.dbo.Orders orc on obr.orc_set_id = orc.orc_set_id
INNER join mosaiq.dbo.cpt cpt on obr.prs_id = cpt.prs_id
left join [MGBBRPSQLDBS1\UNMMGSQLDWPROD].unmmgdss.dss.proc_dim IDX on left(cpt.cpt_code,5) = IDX.proc_Cd and IDX.proc_cd <> ' '
WHERE obr.version = 0		-- Get the tip level (newest version) only -- don't need history of order request changes	
and orc.Order_Type = 1	-- ========Observation Orders (A Referral is an observation order) ================ 
and obr.Obs_dtTm  >= '2010-01-01'  

select			
	B.prs_id,
	B.proc_key_IDX,
	IDX.proc_name		as proc_name_IDX,
	IDX.proc_cd			as proc_cd_IDX,
	IDX.proc_cat_name	as proc_cat_IDX,
	IDX.proc_unmmg_cat  as proc_cat_mg_idx
INTO #IDX_Match
from (
		select		-- Get distinct list of codes that might have IDX CPT/HCPCS (I didn't include Scheduling codes because those that are true CPT/HCPCS should also be in the other sets) 
			distinct A.prs_id, A.proc_key_IDX
		from (
				SELECT		----  Get the CPTs that are used in Billing
					#MQ_CPT_ALL.prs_id,
					#billing.proc_key_IDX as proc_key_IDX
				FROM #MQ_CPT_ALL.#MQ_CPT_ALL 
				left join #billing on #MQ_CPT_ALL.prs_id = #billing.prs_id 
				union
					SELECT  ----  Get the HCPCS codes
					#MQ_CPT_ALL.prs_id,
					#HCPCS.proc_key_IDX  as proc_key_IDX
				FROM #MQ_CPT_ALL.#MQ_CPT_ALL 
				left join #HCPCS on #MQ_CPT_ALL.prs_id = #HCPCS.prs_id					
				UNION
				SELECT		----  Get the codes used in observation orders
					#MQ_CPT_ALL.prs_id,
					#Observation_orders.proc_key_IDX  as proc_key_IDX
				FROM #MQ_CPT_ALL.#MQ_CPT_ALL 				
				left join #Observation_orders	on #MQ_CPT_ALL.prs_id = #Observation_orders.prs_id
				) as A
			where proc_key_IDX is not null
		) as B
left Join  [MGBBRPSQLDBS1\UNMMGSQLDWPROD].unmmgdss.dss.proc_dim IDX on B.proc_key_IDX = IDX.proc_key  and IDX.proc_cd <> '?'



-- ================================================================================================================================
----- Get all Mosaiq CPT Codes and Classify ---------------------------

select DISTINCT
		A.prs_id,
		A.cpt_code,		-- CPT, HSCPCS, and scheduling category/scheduling activity
		A.hsp_code as hsp_code_mq,        --  cpt_code is not (usually) set for drugs, but hsp is (should be); hsp is also for scheduling/ordering
		A.drg_id as drg_id_mq,		 -- not set for all drugs.  FK to Mosaiq.dbo.Drug
		A.description as cpt_desc_mq,		
		A.is_Administrative,
		A.is_billing,
		A.is_drug_CPT, -- this is ALL HCPCS including drugs and drug order activites;-- misnomer since drug codes are hcpcs, not cpts (sorry!)
		A.is_Scheduling,
		A.is_ordering,
		isNULL(A.proc_cd_IDX, ' ')		as proc_cd_IDX,
		isNULL(A.proc_name_idx, ' ')	as proc_name_idx,
		isNULL(A.proc_cat_IDX, ' ')		as proc_cat_IDX,
		isNULL(A.proc_cat_mg_idx, ' ')	as proc_cat_mg_IDX,
		isNULL(A.proc_key_IDX, ' ')		as proc_key_IDX,
		isNULL(A.sch_activity_mq, ' ')	as  sch_activity_mq   -- same as hsp_code, but added field to make it easy to remember
into #MQ_CPT_Classified
	from (
	select
			#MQ_CPT_ALL.prs_id,
			#MQ_CPT_ALL.hsp_code,    --  hsp_code SHOULD be used for drugs, not cpt
			#MQ_CPT_ALL.cpt_code,
			#MQ_CPT_ALL.drg_id,		 -- misnomer since drug codes are hcpcs, not cpts (sorry!)
			#MQ_CPT_ALL.description,
			#IDX_Match.proc_key_IDX,
			case when #administrative.prs_id is null then 'N' else 'Y' end is_Administrative,
			case when #billing.prs_id is null		 then 'N' else 'Y' end is_billing,
			case when #HCPCS.prs_id is null			 then 'N' else 'Y' end is_drug_CPT, -- this is ALL HCPCS including drugs and drug order activites (good enough for Government Work :)
			case when #Scheduling_Activities.prs_id is null then 'N' else 'Y' end is_Scheduling,
			case when #Observation_orders.prs_id	is null then 'N' else 'Y' end is_ordering,
			#IDX_Match.proc_name_idx,
			#IDX_Match.proc_cd_IDX,
			#IDX_Match.proc_cat_IDX,
			#IDX_Match.proc_cat_mg_idx,
			isnull(#Scheduling_Activities.hsp_code, ' ') as sch_activity_mq -- not all CPTs are used in scheduling; added this so you don't have to think about which field maps to scheduling.activity
	from #MQ_CPT_ALL  
	left join #administrative		 on #MQ_CPT_ALL.prs_id = #administrative.prs_id
	left join #billing				 on #MQ_CPT_ALL.prs_id = #billing.prs_id
	left join #HCPCS				 on #MQ_CPT_ALL.prs_id = #HCPCS.prs_id
	left join #Scheduling_Activities on #MQ_CPT_ALL.prs_id = #Scheduling_Activities.prs_id
	left join #Observation_orders	 on #MQ_CPT_ALL.prs_id = #Observation_orders.prs_id
	left join #IDX_Match			 on #MQ_CPT_ALL.prs_id = #IDX_Match.prs_id 
) as A

TRUNCATE TABLE MosaiqAdmin.dbo.Ref_CPTs_and_Activities
INSERT INTO MosaiqAdmin.dbo.Ref_CPTs_and_Activities
Select *,
GetDate() as run_date
from #MQ_CPT_Classified


END
GO

