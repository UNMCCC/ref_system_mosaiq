# ref_system_mosaiq
The UNM Comprehensive Cancer Center (UNMCCC) uses the "Ref system" to extract, curate and stage a set of multi-uses datamarts using stored procedures.  

A SQL server database powering the Mosaiq application serves as the local electronic health system (EHS) for the UNMCCC. As any EHS, Mosaiq tries to 
stay away from opinions to data entry and allows to be configured in lax ways. UNMCCCs has a fair share of funky uses, and as a result, 
canned reports or custom reports often loss accuracy and precision.  

We created a set of stored procedures that curate and compensate many known data oddities within UNMCCCs Mosaiq DB.  We stage datamarts for 
patients, visits, diagnoses, procedures, orders, charges, assessments and the likes. Resulting datamarts are well cleaned and usable for different reporting needs,
including feeding UNMCCCs implementation of the OHDSI OMOP data model.  

Is this transferable to other Mosaiq implementations? Perhaps, but the code would have to be adapted and refactored.  The UNMCCC here uses 
Github as version control system. If any collaboration arises, perfect. Welcome!
