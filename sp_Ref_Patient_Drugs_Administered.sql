USE [MosaiqAdmin]
GO

/****** Object:  StoredProcedure [dbo].[sp_Ref_Patient_Drugs_Administered]    Script Date: 3/8/2023 10:53:45 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [dbo].[sp_Ref_Patient_Drugs_Administered]

-- Drugs administered in-house for each patient
-- Flag activities as whether they are used in scheduling or billing and classify by validity and use 
-- Originally built for RS21 OMOP extract, but useful in other visit reporting.
-- Must be maintained with addition of new scheduling activities.  
-- Billing CPTs will be picked up automatically from IDX


AS
BEGIN

SET NOCOUNT ON;

if object_id('tempdb..#OLD') is not null
	drop table #Pat_Visits;

if object_id('tempdb..#adm_NEW') is not null
	drop table #adm_NEW;

if object_id('tempdb..#DrugCodeMap') is not null
	drop table #DrugCodeMap;

if object_id('tempdb..#NEW') is not null
	drop table #NEW;

if object_id('tempdb..#Data') is not null
	drop table #Data;

SELECT * 
INTO #OLD
FROM Ref_Patient_Drugs_Administered

DECLARE @LastAdmDtTm dateTime
SET @LastAdmDtTm = 
(Select isNULL(max(adm_Start_DtTm) , '2010-01-01')
FROM Ref_Patient_Drugs_Administered)


SELECT 
	RXA.RXA_SET_ID, 
	RXA.RXO_Set_ID,  -- if Pharm Order data is needed, use RXO_Set_ID to 
                         -- join  Mosaiq.dbo.vw_PharmOrd_Derived_Data to this table
	RXA.Orc_set_ID,  -- Order data  
	RXA.Pat_ID1, 
	mosaiq.dbo.fn_Date(RXA.adm_dtTm) as Adm_Date,
	RXA.Adm_DtTm	as Adm_Start_DtTm,
	RXA.Adm_End_DtTm,
	RXA.Adm_code,		-- Drug.Drg_id

	CASE -- get a CPT code in case drug cannot be identified via label, type or MEDID 
             --  (which is used to map to RxNorm and CXV vocabularies)
		when RXA.Adm_code <> 0 -- drug_id assigned (this is the norm) 
		then Drg.Drug_Label		
		Else isNull(cptRef.CPT_desc_mq, ' ')  --no drug name listed, only PRS_ID (CPT) given. 
                                                   -- Occurred Pre-2016 for saline and dextrose solutions administered
	END Drug_Label,				-- add a new column for this in extract 
	isNULL(Drg.generic_name, '') as Drug_Generic_Name,
	isNULL(mosaiq.dbo.fn_GetObsDefLabel(Drg.Drug_Type), ' ') as Drug_Type, -- add a new column for this in extract
	drg.MEDID AS FDB_MedID,  -- add a new column for this in extract
	drg.RMID as FDB_RMID,
	GCNSeqNo,
	RXA.Adm_Amount,			--QUANTITY
	Mosaiq.dbo.fn_GetObsDefLabel(RXA.Adm_Units)   as Adm_Units_desc,  -- DOSE_UNIT_SOURCE_VALUE
	Mosaiq.dbo.fn_GetObsDefLabel(RXA.Admin_Route) as Adm_Route_desc,  -- ROUTE_SOURCE_VALUE
	RXA.Status_Enum,
	Case
		when RXA.status_enum = 0 then 'Unknown' 
		when RXA.status_enum = 1 then 'Void' 
		when RXA.status_enum = 2 then 'Close' 
		when RXA.status_enum = 3 then 'Complete' 
		when RXA.status_enum = 4 then 'Hold' 
		when RXA.status_enum = 5 then 'Approve'
		when RXA.status_enum = 6 then 'Process Lock'  -- Only occurs in-app
		when RXA.status_enum = 7 then 'Pending'
		else 'other' end adm_status,
	orc.order_type,			-- pre-2013 order_type = 2; post-2013 order_type = 4; 
	orc.Ord_Provider as ordering_provider_id,
	drg.drg_id,
	RXA.PRS_ID			-- populated pre-2016 when no drug_id specified (ex: Saline solns) -- Unique key for Mosaiq.dbo.CPT and MosaiqAdmin.dbo.Ref_CPTs_and_Activities 
into #adm_NEW
	FROM MOSAIQ.dbo.PharmAdm RXA 
	LEFT JOIN mosaiq.dbo.Drug drg on RXA.Adm_code = Drg.DRG_ID 
	LEFT JOIN MosaiqAdmin.dbo.Ref_CPTs_and_Activities cptRef on RXA.PRS_ID = cptRef.PRS_ID --and cptRef.cpt_code is not null and cptRef.cpt_code <> ' ' -- RXA.prs_id is null except when there is no RXA.Adm_code specified)
	LEFT JOIN Mosaiq.dbo.Orders orc	on rxa.orc_set_id = orc.orc_set_id and orc.version = 0
	WHERE RXA.Adm_DtTm is not null  -- actually recorded the drug as having been administered at a given time
	and RXA.status_enum not in (1,4,7)
	and RXA.adm_code <> 929 -- drug_label = 'DO NOT USE'  -- there is also adm_code 383 (Acetaminophen DO NOT USE) ??
	and RXA.adm_dtTm >= '2010-01-01'
	and RXA.adm_DtTm >  @LastAdmDtTm


-- get single mapping by medId and codeset (remove duplicates)
SELECT medId, rmid, codeset, CodeValue, CodeDescription, BestMatch, CodeType,
Row_Number () OVER (Partition by medId, codeset order by  bestMatch desc, codevalue desc) as seq  
	-- if there is 1-best-match select that one
	-- if there are multiple best-matches, select the record with the highest codevalue 
        -- (arbitrary assuming higher # is newer)
	-- if there are no best batches, select the record with the highest best-match 
        -- (arbitrary assuming higher # is newer )
INTO #DrugCodeMap -- get only 1 map per medId in case of multiple entries in DrugCodeMapping 
FROM Mosaiq.dbo.DrugCodeMapping 
WHERE (medId is not null or RMID is not null) --and codeset is not null
ORDER BY codeDescription,  seq            --codeset, codevalue, codedescription

SELECT DISTINCT
	#adm_NEW.PAT_ID1,
	#adm_NEW.Adm_Date,
	#adm_NEW.Adm_Start_DtTm,
	#adm_NEW.Adm_End_DtTm,
	#adm_NEW.Adm_code,
	#adm_NEW.Drug_Label,
	#adm_NEW.Drug_Generic_Name,
	#adm_NEW.Drug_Type,
	#adm_NEW.FDB_MedID,		-- FDB_RMID is not populated so linking to dcm on MedID
	dcm1.CodeValue	as RxNorm_CodeValue,
	dcm1.CodeType	as RxNorm_CodeType,
	dcm2.CodeValue	as CVX_CodeValue,
	dcm2.CodeType	as CVX_CodeType,
	#adm_NEW.Adm_Amount,
	#adm_NEW.Adm_Units_desc as Adm_Units,
	#adm_NEW.Adm_Route_Desc as Adm_Route,
	#adm_NEW.Adm_Status,
	#adm_NEW.order_type,
	#adm_NEW.ordering_provider_id,
	#adm_NEW.drg_id,
	#adm_NEW.prs_id,
	Sch.apptDt_PatID,
	#adm_NEW.RXA_Set_ID, 
	#adm_NEW.RXO_Set_ID, 
	#adm_NEW.ORC_Set_ID,
	getDate() as run_date
INTO #NEW
FROM #adm_NEW
LEFT JOIN MosaiqAdmin.dbo.Ref_SchSets Sch on #adm_NEW.pat_id1 = sch.pat_id1 and #adm_NEW.Adm_Date = sch.appt_date  
LEFT JOIN #DrugCodeMap dcm1 on #adm_NEW.FDB_MedID = dcm1.MedID and dcm1.CodeSet = 1  and dcm1.seq = 1 -- CodeSet = RxNorm   --seq eliminates dups
LEFT JOIN #DrugCodeMap dcm2 on #adm_NEW.FDB_MedID = dcm2.MedID and dcm2.CodeSet = 2  and dcm2.seq = 1 -- CodeSet = CVX		--seq eliminates dups

/* In 5% of the records, drugs were administered but there is no captured appt.  
Example:  pat_id1=5xxx7 / appt_dt=2021-11-02 --> patient was scheduled for Rad Tx but was in hospital so appt was statused as B(reak) -- but patient was given morhpine?  was patient brought here?  
Example:  pat_id1=1xxx2 / appt_Dt=2010-01-05 --> patient was scheduled for infusion appt, but appt not statused -- 2 drugs admimstered
select top 1000 * from #adm2
select top 1000 * from #adm2 where first_SchSet_of_day is null 
select count(*) from #adm
select count(*) from #adm2
select count(*) from #adm2 where first_SchSet_of_day is null
select max(adm_date) from #adm2 where first_SchSet_of_day is null
*/

SELECT DISTINCT *
INTO #Data
FROM (
	SELECT 
		pat_id1,
		adm_date,
		adm_start_DtTm,
		adm_end_dtTm,
		adm_code,
		drug_label,
		drug_generic_name,
		drug_type,
		FDB_MedID,
		RxNorm_CodeValue,
		RxNorm_CodeType,
		CVX_CodeValue,
		CVX_CodeType,
		adm_amount,
		adm_units,
		adm_route,
		adm_status,
		order_type,
		ordering_provider_id,
		drg_id,
		prs_id,
		ApptDt_PatID,
		rxa_set_id,
		rxo_set_id,
		orc_set_id,
		run_date
	FROM #OLD
	UNION
	SELECT 
		pat_id1,
		adm_date,
		adm_start_DtTm,
		adm_end_dtTm,
		adm_code,
		drug_label,
		drug_generic_name,
		drug_type,
		FDB_MedID,
		RxNorm_CodeValue,
		RxNorm_CodeType,
		CVX_CodeValue,
		CVX_CodeType,
		adm_amount,
		adm_units,
		adm_route,
		adm_status,
		order_type,
		ordering_provider_id,
		drg_id,
		prs_id,
		ApptDt_PatID,
		rxa_set_id,
		rxo_set_id,
		orc_set_id,
		GetDate() as RunDate
	FROM #NEW
) as A

TRUNCATE TABLE MosaiqAdmin.dbo.Ref_Patient_Drugs_Administered
INSERT INTO MosaiqAdmin.dbo.Ref_Patient_Drugs_Administered
Select * 
from #Data

END
GO


