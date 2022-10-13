USE [MosaiqAdmin]
GO

/****** Object:  StoredProcedure [dbo].[sp_Ref_Patients]    Script Date: 10/13/2022 4:29:50 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE PROCEDURE [dbo].[sp_Ref_Patients]
	-- All patient ids going back to 2008 with MRN, Name, and a Validity Indicator
	-- A pat_id1 will be marked as invalid if the ida(MRN) associated with it is blank
	-- And if it is an identified patient established for reporting
	-- ALL Patients in the Mosaiq DB were checked.  This needs to be monitored.  
	-- Training needs to be done to catch newly created Test Patients.
	-- Usage:  Select pat_id1 from MosaiqAdmin.dbo.Patient_List where is_valid = 'Y'
	-- Debbie Healy 11/17/21

AS
BEGIN
---------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#PatList') IS NOT NULL
	DROP TABLE #PatList;

select A.pat_id1, ident.ida, A.pat_name as pat_ID1_name,
case when pat_name in ('BLOCK, SCHEDULE', 'DO NOT BOOK, DO NOT BOOK', 'SAMPLE, PATIENT', 'TEST, A', 'TEST, BASIL B.', 'TEST, JUSTIN B.', 'TEST, PROVIDER', 'TESTER, TESTY', 'TESTOFC, PATIENT7')
		or pat_name in ('HOLD, HOLD', 'NEW/OLD, START', 'PHYSICS, AGILITY', 'PHYSICS, TOMO', 'TESTOFC, PATIENT7', 'IMPAC, IMPAC', 'AAAAAAAAA, AAAAAAAAAAA', 'TESTLAB, BABY','ABD_TEST, IMRT', 'PHANTOM, MOSAIQ26', 'PHANTOM, CHEESE T.')
		or pat_name in ('QA-SYNERGY, MONTHLY', 'TRAUMA-ALERT, ZEL Q.', 'TESTING, VELOS INTERFACE', 'TOMOPHANT,  ANN', 'NRG, CC003', 'IGRT, PENTAGUIDE','IGRT, QA 2 BM')
		Or pat_name  like '%Physics%'-- just to be safe
		or pat_name like '%Test,%' 
		or pat_name like '%, Test'
		or pat_name like '%Do Not%'
		or pat_name like '%MEETING%'
		or pat_name  = 'NEW, NEW' -- added 9/3/2021
		or pat_name = 'XXXXXXXXXXXXXXXXXXX, XXXXXXXXXXXXXXXXXXXX' -- added 9/3/2021
		or pat_name  = 'IMPAC, IMPAC'		 -- added 9/3/2021
		or pat_name = 'NEW START, PT'		-- added 9/3/2021
		or pat_name  = 'MOUSE, MICKEY'		-- added 9/3/2021
		or pat_name = 'PHANTOM 2, V15'
		or pat_name like '%PHANTOM%'
		or pat_name like 'ZZ%'
		or pat_name like 'XX%'
		or pat_name like 'XVI %'
		or pat_name like '%Daily_QA%'
		or pat_name  = 'ZZZ - TEST, MED ONC'
		or pat_name  = 'ECLIPSE, WATERPHANTOM'
		or pat_name like '%IGRT QA%'
		or pat_name like '%IMAGING QA%'	
		or pat_name like '%DOSIMETRY%'
		or pat_name  = 'SNOOPY, DOGGIE'
		or a.Pat_id1 in ( 0, 123456)
		or ida IN ('0011234567','0000000', '00000000','0000000001','0123456', '11','123', '12345', '123456', '1234567', '11111', '333333', '7777', '88888', '999999', '9999998') -- '11 = Fence, Picket'! Yikes
		or ida in ('VMAT', 'testdmlc', 'QA12357', 'QA12352', 'QA12350', 'QA12349', 'QA12346', 'Inactive', 'CAT Imaging QA')
		or ida in ('9999998', '9999999','CAT Imaging QA','D12345','do not use','Do not use.','Dup Acct 772340','Duplicate','faketest','Inactive','LUCY-A16 092014')
		or ida in ('MonacoPhantom','Mosaiq','MV imaging QA','Pelvis RPC 14','PH-001','PH-002','Phantom','QA 092613','QA-Agility','QA-Synergy','QA04302013','QA102416','QA102516')
		or ida in ('QA12346','QA12348','QA12350','QA12351','QA12352','QA12357','QA12359','testdmlc','VMAT','Winston-Lutz','ZZZ000','zzz1','zzz2','zzz3','zzz5','zzzz2','zzzz3')
		or ida like '%QA%'
		or ida like '%Z%'
		or ida like '%A%' or ida like '%B%' or ida like '%C%' or ida like '%D%' or ida like '%E%' or ida like '%F%' or ida like '%G%' or ida like '%H%' or ida like '%I%'
		or ida like '%J%' or ida like '%K%' or ida like '%L%' or ida like '%M%' or ida like '%N%' or ida like '%O%' or ida like '%P%' or ida like '%Q%' or ida like '%R%'	
		or ida like '%S%' or ida like '%T%' or ida like '%U%' or ida like '%V%' or ida like '%W%' or ida like '%X%' or ida like '%Y%' or ida like '%Z%' -- future proofing!	
		or a.Pat_id1 is null
		or ida = ' '
	then 'N'
	else 'Y'
end is_Valid
into #PatList
from (
	select distinct isNULL(pat.pat_id1, 0) as pat_id1,
	mosaiq.dbo.fn_GetPatientName(pat.pat_id1, 'NAMELFM') as pat_name
	from mosaiq.dbo.patient pat
) as A
left join mosaiq.dbo.ident on a.pat_id1 = ident.pat_id1

TRUNCATE TABLE  MosaiqAdmin.dbo.Ref_Patients
INSERT INTO MosaiqAdmin.dbo.Ref_Patients
select 
	pat_id1, 
	ida,
	pat_id1_name,
	is_Valid,
	getdate() as run_date
from #patList
order by pat_id1




END
GO

