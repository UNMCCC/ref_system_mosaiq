USE [MosaiqAdmin]
GO

/****** Object:  StoredProcedure [dbo].[sp_Ref_Patient_Diagnoses]    Script Date: 10/19/2022 1:40:28 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO





ALTER PROCEDURE [dbo].[sp_Ref_Patient_Diagnoses]

-- Debbie Healy
-- RE-WROTE to get diagnosis data from Ref_SchSet_Charges (added Dx data to Ref_SchSet_Charges on  8/30/2022)
--
-- Get unique set of Diagnoses for each patient for each day of appointments.  
-- Diagnoses Data are gathered from Charge Code Capture processes, distilling diagnoses for each procedure of the day into a unique list of diagnoses for the day.
-- Data are gathered from the Ref_SchSet_Charges table
-- The Diagnosis List for each Patient/appt date

-- Note that there is a time lag between the date-of-service and Charge Capture, so there may not be a set of DX codes associated with each day.
-- We need to do an analysis of this and see whether we need to fill in the gap with Diagnoses associated with Orders (only 1/order and less specific) until the Charge DXs are coded.
-- Data originally gathered for the RS21 OMOP model but has been practical uses for Visit Reporting
-- Debbie Healy 11/17/21
-- Debbie 04/04/2022 -- added Diagnosis Description
--		Note that the Topog table contains a boolean field called isCancer, but this is set to indicate cancer for both malignancies and non-malignant tumors, so not used

AS
BEGIN


if object_id('tempdb..#Old') is not null
	drop table #OLD;

select *
into #OLD
from MosaiqAdmin.dbo.Ref_Patient_Diagnoses

if object_id('tempdb..#OldIDs') is not null
	drop table #OLDIDs;

SELECT distinct 
pat_id1,
Appt_Date, -- even if there is no schedule in MQ, this will be the appt date derived from charge.proc_DtTm
--ApptDt_Pat_ID, 
tpg_id
into #OldIDs
from #OLD

select count(*) from #old

if object_id('tempdb..#UNQ_DX') is not null
	drop table #UNQ_DX;
	SELECT DISTINCT -- REMOVE DX DUPS FOR PAT/DOS
		A.apptDt_PatID, 
		pat_id1,
		appt_date,
		A.tpg_id,
		TPG.Diag_Code,
		TPG.description as Diag_desc
	INTO #UNQ_DX
	FROM  ( -- TPG (DX) ID FOR EACH CHARGE
			select distinct 
			ref_chg.apptDt_PatID, -- Visit Occurence ID for OMOP
			ref_chg.pat_id1,
			ref_chg.appt_date,
			ref_chg.tpg_id1 as tpg_id
			from MosaiqAdmin.dbo.Ref_SchSet_Charges ref_chg
			where ref_chg.tpg_id1 is not null
			UNION
			select distinct 
			ref_chg.apptDt_PatID,
			ref_chg.pat_id1,
			ref_chg.appt_date,
			ref_chg.tpg_id2 as tpg_id
			from MosaiqAdmin.dbo.Ref_SchSet_Charges ref_chg
			where ref_chg.tpg_id2 is not null
			UNION 
			select distinct 
			ref_chg.apptDt_PatID, -- Visit Encounter
			ref_chg.pat_id1,
			ref_chg.appt_date,
			ref_chg.tpg_id3 as tpg_id
			from MosaiqAdmin.dbo.Ref_SchSet_Charges ref_chg
			where ref_chg.tpg_id3 is not null
			UNION
			select distinct 
			ref_chg.apptDt_PatID,
			ref_chg.pat_id1,
			ref_chg.appt_date,
			ref_chg.tpg_id4 as tpg_id
			from MosaiqAdmin.dbo.Ref_SchSet_Charges ref_chg
		--	INNER JOIN Mosaiq.dbo.charge chg on Ref_SchSet_Charges.chg_id = chg.chg_id 
			where ref_chg.tpg_id4 is not null
		) as A
		INNER JOIN Mosaiq.dbo.Topog TPG ON A.TPG_ID = TPG.TPG_ID  -- if you add description in ref_schSet_charges can remove this join

if object_id('tempdb..#New') is not null
	drop table #New;

SELECT 		
	A.pat_id1,
	A.appt_date,
	A.apptDt_PatID, 
	A.tpg_id,
	A.Diag_Code,
	A.Diag_desc,
	getDate() as run_date
into #New
FROM (
	SELECT distinct 
		#OldIds.pat_id1 as Old_Pat_ID1,
		#UNQ_Dx.pat_id1,
		#UNQ_Dx.appt_date,
		#UNQ_Dx.apptDt_PatID, 
		#UNQ_Dx.tpg_id,
		#UNQ_Dx.Diag_Code,
		#UNQ_Dx.Diag_desc
	from #UNQ_Dx
	left join #OldIds on #UNQ_DX.pat_id1 = #OldIds.pat_id1 and  #UNQ_DX.Appt_Date = #OldIds.Appt_Date and #UNQ_DX.tpg_id = #OldIds.tpg_id
) as A
where A.Old_Pat_id1 is NULL 


if object_id('tempdb..#Data') is not null
	drop table #Data;

select 	
	A.pat_id1,
	A.appt_date,
	A.apptDt_PatID,
	A.TPG_ID,
	A.Diag_Code,
	A.Diag_desc,
	A.run_date
into #data
from (
	select *
	from #Old
	union
	select * 
	from #New
) as A


TRUNCATE TABLE MosaiqAdmin.dbo.Ref_Patient_Diagnoses
INSERT INTO MosaiqAdmin.dbo.Ref_Patient_Diagnoses
select * from #data

TRUNCATE TABLE MosaiqAdmin.dbo.Ref_Patient_Diagnoses_NEW_RS21Incremental
INSERT INTO MosaiqAdmin.dbo.Ref_Patient_Diagnoses_NEW_RS21Incremental
select * from #new


END
GO


