USE [MosaiqAdmin]
GO

/****** Object:  StoredProcedure [dbo].[sp_Ref_Patient_Drugs_Administered]    Script Date: 3/8/2023 10:52:37 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO












CREATE PROCEDURE [dbo].[sp_Ref_Patient_Drugs_Administered]

-- Drugs administered in-house for each patient
-- Flag activities as whether they are used in scheduling or billing and classify by validity and use 
-- Originally built for RS21 OMOP extract, but useful in other visit reporting.
-- Must be maintained with addition of new scheduling activities.  Billing CPTs will be picked up automatically from IDX
--

AS
BEGIN
-- [dbo].[vw_PharmOrd_Derived_Data] to this table
-- Table/Field References changed 


-- for RS21 OMOP model, we need to select "procedures" from Charge Table to be able to use CPT codes to classify the appointments. But, we need to exclude DRUG CPT codes from the "Procedure" extract.
-- to do -- reach out to Andi/Candy about what it means if a drug has adm_amount = 0 -- give example to them to help determine if I can exclude these from the extract
-- drop table #last, #OLD
SELECT * 
INTO #OLD
FROM Ref_Patient_Drugs_Administered

/* For Incremental Add */

DECLARE @LastAdmDtTm dateTime
SET @LastAdmDtTm = 
(Select isNULL(max(adm_Start_DtTm) , '2010-01-01')
FROM Ref_Patient_Drugs_Administered)
SELECT @LastAdmDtTm 

--  drop table #adm_NEW
SELECT 
	RXA.RXA_SET_ID, 
	RXA.RXO_Set_ID,  -- if Pharm Order data is needed, use RXO_Set_ID to join  Mosaiq.dbo.vw_PharmOrd_Derived_Data to this table
	RXA.Orc_set_ID,  -- Order data  
	RXA.Pat_ID1, 
	mosaiq.dbo.fn_Date(RXA.adm_dtTm) as Adm_Date,
	RXA.Adm_DtTm	as Adm_Start_DtTm,
	RXA.Adm_End_DtTm,
	RXA.Adm_code,		-- Drug.Drg_id
	isNull(Drg.Drug_Label, ' ') as Drug_Label,
	isNull(Drg.Generic_name, ' ') as Drug_Generic_Name, 
	--CASE -- get a CPT code in case drug cannot be identified via labe, type or MEDID (which is used to map to RxNorm and CXV vocabularies)
		--when RXA.Adm_code <> 0 -- drug_id assigned (this is the norm) 
		--then Drg.Drug_Label		
		--Else isNull(cptRef.CPT_desc_mq, ' ')		--no drug name listed, only PRS_ID (CPT) given.  Occurred Pre-2016 for saline and dextrose solutions administered
	--END Drug_Label,				-- add a new column for this in extract 
	--CASE -- get a CPT code in case drug cannot be identified via label, type or MEDID (which is used to map to RxNorm and CXV vocabularies)
		--when RXA.Adm_code <> 0 -- drug_id assigned (this is the norm) 
		--then mosaiq.dbo.fn_GetObsDefLabel(Drg.Drug_Type)
		--else isnull(cptRef.CPT_desc_mq, ' ')  -- no drug name listed, only PRS_ID (CPT) given.  Occurred Pre-2016 for saline and dextrose solutions administered
	--END Drug_Generic_Name,  -- add a new column for this in extract 
	isNULL(mosaiq.dbo.fn_GetObsDefLabel(Drg.Drug_Type), ' ') as Drug_Type, -- add a new column for this in extract
	RXA.Adm_Amount,			--QUANTITY
	isNull(Mosaiq.dbo.fn_GetObsDefLabel(RXA.Adm_Units), ' ')  as Adm_Units_desc,  -- DOSE_UNIT_SOURCE_VALUE
	isNull(Mosaiq.dbo.fn_GetObsDefLabel(RXA.Admin_Route), ' ')  as Adm_Route_desc,  -- ROUTE_SOURCE_VALUE
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
	drg.MEDID AS FDB_MedID,  -- add a new column for this in extract
	drg.RMID as FDB_RMID,
	drg.GCNSeqNo,
	RXA.PRS_ID			-- populated pre-2016 when no drug_id specified (ex: Saline solns) -- Unique key for Mosaiq.dbo.CPT and MosaiqAdmin.dbo.Ref_CPTs_and_Activities 
into #adm_NEW
	FROM MOSAIQ.dbo.PharmAdm RXA 
--	INNER JOIN MosaiqAdmin.dbo.RS21_Patient_List_for_Security_Review Subset on RXA.pat_id1 = Subset.Pat_ID1
	LEFT JOIN mosaiq.dbo.Drug drg on RXA.Adm_code = Drg.DRG_ID 
	LEFT JOIN MosaiqAdmin.dbo.Ref_CPTs_and_Activities cptRef on RXA.PRS_ID = cptRef.PRS_ID --and cptRef.cpt_code is not null and cptRef.cpt_code <> ' ' -- RXA.prs_id is null except when there is no RXA.Adm_code specified)
	LEFT JOIN Mosaiq.dbo.Orders orc	on rxa.orc_set_id = orc.orc_set_id and orc.version = 0
	WHERE RXA.Adm_DtTm is not null  -- actually recorded the drug as having been administered at a given time
	and RXA.status_enum not in (1,4,7)
	and RXA.adm_code <> 929 -- drug_label = 'DO NOT USE'  -- there is also adm_code 383 (Acetaminophen DO NOT USE) ??
	and RXA.adm_dtTm >= '2010-01-01'
	and RXA.adm_DtTm >  @LastAdmDtTm
-- WHAT ABOUT Adm_AMT = 0??? why does this happen? -- keeping 0 in for Betsy's Drug Reconciliation
	--and RXA.pat_id1 =12480  and mosaiq.dbo.fn_date(adm_dttm) = '2015-07-15'  -- had dups



-- drop table #DrugCodeMap
-- get single mapping by medId and codeset (remove duplicates)
select medId, codeset, CodeValue, CodeDescription, BestMatch, CodeType,
Row_Number () OVER (Partition by medId, codeset order by  bestMatch desc, codevalue desc) as seq  
	-- if there is 1-best-match select that one
	-- if there are multiple best-matches, select the record with the highest codevalue (arbitrary assuming higher # is newer)
	-- if there are no best batches, select the record with the highest best-match (arbitrary assuming higher # is newer )
	-- 3/7/22 -- learned more about this mapping table from Mike (RS21) and this is probably not the best way to select the RxNorm 
	-- 3/7/22 --SBD (Branded Drug), SCD (Clinical Drug); looks like MEDID is name/route / many-to-1 from medid to rxNorm.
into #DrugCodeMap -- get only 1 map per medId in case of multiple entries in DrugCodeMapping 
from Mosaiq.dbo.DrugCodeMapping 
where medId is not null and codeset is not null
order by medId, seq --codeset, codevalue, codedescription

-- drop table #NEW
select Distinct 
	#adm_NEW.PAT_ID1,
	#adm_NEW.Adm_Date,
	#adm_NEW.Adm_Start_DtTm,
	#adm_NEW.Adm_End_DtTm,
	#adm_NEW.Adm_code,
	#adm_NEW.Drug_Label,
	#adm_NEW.Drug_Generic_Name,
	#adm_NEW.Drug_Type,
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
	#adm_NEW.FDB_MedID,
	dcm1.CodeValue	as RxNorm_CodeValue,
	dcm1.CodeType	as RxNorm_CodeType,
	dcm2.CodeValue	as CVX_CodeValue,
	dcm2.CodeType	as CVX_CodeType,
	#adm_NEW.GCNSeqNo,
	getDate() as run_date
into #NEW
from #adm_NEW
left join MosaiqAdmin.dbo.Ref_SchSets Sch on #adm_NEW.pat_id1 = sch.pat_id1 and #adm_NEW.Adm_Date = sch.appt_date  
left join #DrugCodeMap dcm1 on #adm_NEW.FDB_MedID = dcm1.MedID and dcm1.CodeSet = 1  and dcm1.seq = 1 -- CodeSet = RxNorm   --seq eliminates dups
left join #DrugCodeMap dcm2 on #adm_NEW.FDB_MedID = dcm2.MedID and dcm2.CodeSet = 2  and dcm2.seq = 1 -- CodeSet = CVX		--seq eliminates dups






-- select count(*) from #adm_NEW
-- select count(*) from #NEW
-- select count(*) from #OLD
-- drop table #data


/* In 5% of the records, drugs were administered but there is no captured appt.  
Example:  pat_id1=54037 / appt_dt=2021-11-02 --> patient was scheduled for Rad Tx but was in hospital so appt was statused as B(reak) -- but patient was given morhpine?  was patient brought here?  
Example:  pat_id1=14282 / appt_Dt=2010-01-05 --> patient was scheduled for infusion appt, but appt not statused -- 2 drugs admimstered
select top 1000 * from #adm2
select top 1000 * from #adm2 where first_SchSet_of_day is null 
select count(*) from #adm
select count(*) from #adm2
select count(*) from #adm2 where first_SchSet_of_day is null
select max(adm_date) from #adm2 where first_SchSet_of_day is null
*/
-- drop table #Data
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
		FDB_MedID,
		RxNorm_CodeValue,
		RxNorm_CodeType,
		CVX_CodeValue,
		CVX_CodeType,
		GCNSeqNo,
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
		FDB_MedID,
		RxNorm_CodeValue,
		RxNorm_CodeType,
		CVX_CodeValue,
		CVX_CodeType,
		GCNSeqNo,
		GetDate() as RunDate
	FROM #NEW
) as A
-- drop table #Data

--select top 100 * from #Data
--select count(*) from #old
--select count(*) from #new
--select count(*) from #data
--select distinct run_Date from #data

TRUNCATE TABLE MosaiqAdmin.dbo.Ref_Patient_Drugs_Administered
INSERT INTO MosaiqAdmin.dbo.Ref_Patient_Drugs_Administered
Select * 
from #data



END
GO


