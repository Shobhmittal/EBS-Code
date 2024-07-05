create or replace PACKAGE BODY      "ADRE_INVOICE_EMAIL_PKG" AS
/* 
17-DEC-13  M.H.
Added a second request submit to print a text-only copy to the printer but still 
email PDF version to the customer.  Will generate two CC requests for each customer
but only one will have viewable data (unchecked print on report definition).

20-AUG-15 LP of Tier1
Add Layout to invoice submit requests to pull in the BI PUB template 
Add section to wait on Invoice Print before submitting email or the next one.  
Remove section 3 which was an extra print.

07-DEC-15  M.H.
Removed sending to Sonia and back to SMTP directly to the customer, with AR copied.

13-JUL-16  M.H.
Changed synonym ra_customer_trx to ra_customer_trx_all.  Tripped me up every time 
I had to troubleshoot why invoices weren't emailed.  Still don't understand why
it works within the package but not outside of it.

28-JUL-16  M.H.
Created ARx procedure.  For some unknown reason, the ARx run was trying to pull 
Glen Rock invoices, which came out blank, in addition to the ARx invoices.  
Hard-coded the org into the select statements.

16-OCT-18 S.M.-RACKSPACE
Changed email subject to 'New Invoice' in procedure find_invoices and find_invoices_arx
*/

    PROCEDURE find_invoices (retcode IN OUT VARCHAR2, errbuf IN OUT VARCHAR2) IS
        vDebug     VARCHAR2(10);
        vRetstring VARCHAR2(150) := 'New invoices were found for the the following customers but could not be sent: ';
        vReq       NUMBER;
        vReqEmail  NUMBER;
        vErr       VARCHAR2(2000);
--        l_item_key VARCHAR2(20);
        vOpt        BOOLEAN;
        vToAddress VARCHAR2(100);
        vReq2       NUMBER;
        vLayout     BOOLEAN := TRUE;
        lc_phase            VARCHAR2(50);
        lc_status           VARCHAR2(50);
        lc_dev_phase        VARCHAR2(50);
        lc_dev_status       VARCHAR2(50);
        lc_message          VARCHAR2(50);
        l_req_return_status BOOLEAN;

    BEGIN
    
        -- Added 13-JUL-12 M.H. 
        -- Use profile option for "To" address.
        vToAddress := FND_PROFILE.VALUE_SPECIFIC
                        (name => 'ADRE_EMAIL_INVOICE',
                        user_id => FND_GLOBAL.USER_ID,
                        responsibility_id => NULL,
                        application_id => NULL,
                        org_id => NULL,
                        server_id => NULL); 
                        
        -- Changed 11-OCT-12 M.H.
        -- Removed DISTINCT and added ct.trx_number
        -- So will send seperate PDF invoices
        
        vDebug := '010';
        retcode := '0';
        FND_FILE.PUT_LINE(FND_FILE.LOG, 'New Invoices found for the following customers:');
        FOR rec IN (SELECT ct.sold_to_customer_id,
                           raa_bill_loc.address2 email,
                           hp.party_name,
                           raa_bill_loc.location_id,
                           CT.TRX_NUMBER
                      FROM ra_customer_trx_all ct,
                           hz_cust_accounts rac_bill,
                           hz_parties hp,
                           hz_cust_acct_sites_all raa_bill,
                           hz_party_sites raa_bill_ps,
                           hz_locations raa_bill_loc,
                           hz_cust_site_uses_all su_bill,
                           ra_terms_lines tl
                     WHERE ct.bill_to_site_use_id = su_bill.site_use_id
                       AND ct.bill_to_customer_id = rac_bill.cust_account_id
                       AND rac_bill.party_id = hp.party_id
                       AND su_bill.cust_acct_site_id = raa_bill.cust_acct_site_id
                       AND raa_bill.party_site_id = raa_bill_ps.party_site_id
                       AND raa_bill_loc.location_id = raa_bill_ps.location_id
                       AND ct.printing_pending = 'Y'
                       AND ct.COMPLETE_FLAG = 'Y'
                       AND ct.TERM_ID = TL.TERM_ID(+)
                       AND ct.PRINTING_OPTION IN ('PRI', 'REP')
                       AND NVL(TL.SEQUENCE_NUM, 1) > NVL(ct.LAST_PRINTED_SEQUENCE_NUM,0)
                       AND upper(rtrim(ltrim(raa_bill_loc.address1))) = 'DO NOT MAIL'
                       AND ct.org_id = 43)
                       
        LOOP
            vDebug := '020';
            FND_FILE.PUT_LINE(FND_FILE.LOG, 'Customer (location ID): '||rec.party_name||'('||REC.LOCATION_ID||')');
            FND_FILE.PUT_LINE(FND_FILE.LOG, '--- Invoice: '||rec.trx_number);
            
            vLayout := FND_REQUEST.add_layout ('XBOL', 'ADRE_RAXINV_SEL_CUST','en','US','PDF'); /* LP of Tier1 Set XML layout */
            vOpt :=fnd_request.set_print_options 
                 (copies     =>1);  -- LP of Tier1 added when we decided to dispense with step 3.
            vReq := FND_REQUEST.submit_request(
                            'XBOL',
                    --       'ADRE_RAXINV_SEL_NEW',
                           'ADRE_RAXINV_SEL_CUST',
                            rec.party_name||' - New Invoices Emailed',
                            NULL,
                            FALSE,
                            'TRX_NUMBER', -- p_order_by
                            NULL,
                            NULL,
                            rec.trx_number, --NULL,M.H. 11-OCT-12
                            rec.trx_number, --NULL,M.H. 11-OCT-12
                            NULL,
                            NULL,
                            NULL,
                            NULL, --rec.sold_to_customer_id, --p_customer_id,M.H. 11-OCT-12
                            NULL,
                            'N', --'Y', --p_open_invoice. Must be N for zero dollar invoices
                            'N', --p_check_for_taxyn
                            NULL,
                            'NEW', --p_choice
                            1, --p_header_pages
                            'N', --p_debug_flag
                            10, --p_message_level
                            NULL,
                            NULL,
                            rec.location_id
                             );
                commit;
                
           IF vReq = 0
            THEN
                 vDebug := '030';
                 retcode := '1';
                 vRetstring := vRetstring || rec.party_name;
                 ERRBUF := vRetstring;

           ELSE -- Run email program after waiting for successful finish
            
              LOOP -- wait for invoice print program to finish 
                 l_req_return_status :=
                 fnd_concurrent.wait_for_request (request_id      => vReq
                                            ,INTERVAL        => 10 -- 10 seconds
                                            ,max_wait        => 180 -- 3 minutes
                                             -- out arguments
                                            ,phase           => lc_phase
                                            ,STATUS          => lc_status
                                            ,dev_phase       => lc_dev_phase
                                            ,dev_status      => lc_dev_status
                                            ,message         => lc_message
                                            );                        
                 EXIT
                 WHEN UPPER (lc_phase) = 'COMPLETED' OR UPPER (lc_status) IN ('CANCELLED', 'ERROR', 'TERMINATED');
              END LOOP; 
    --
    --
              IF UPPER (lc_phase) = 'COMPLETED' AND UPPER (lc_status) = 'ERROR' THEN
                 FND_FILE.PUT_LINE(FND_FILE.LOG,'**** The ADRE_RAXINV_SEL_CUST program completed in error. Oracle request id: '||vReq ||' '||SQLERRM);
              ELSIF UPPER (lc_phase) = 'COMPLETED' AND UPPER (lc_status) = 'NORMAL' THEN
                FND_FILE.PUT_LINE(FND_FILE.LOG, '--- ADRE_RAXINV_SEL_CUST request successful for request id: ' || vReq); -- Run email program
                
                vDebug := '040';
                FND_FILE.PUT_LINE(FND_FILE.LOG, '--- Email to ' || rec.party_name ||': '||rec.email);
                ----   Add codeto set print options
                vOpt :=fnd_request.set_print_options 
                 (copies     =>0);
                  ----

                vReqEmail := FND_REQUEST.submit_request(
                            'XBOL',
                           'ADRE_EMAIL_OUTPUT',
                            'Email Invoice to: ' ||rec.email,
                            TO_CHAR(SYSDATE+.010,'DD-MON-YY HH24:MI:SS'),  --12/18 dlf - changed to ~14 minutes was about 7 minutes (.005).  Was 5 .004
                            FALSE,
                            vReq,
                            rec.email||' ;accountsreceivable@arglobal.com', -- use rec.email for automatic email. Use vToAddress (Profile option) to send internally. 
                            'INVOICE',
                            --'New Invoices for '||rec.party_name, --old subject line
                            --rec.email, --Commented by SM-Rackspace as per #1244069 16-Oct-2018
							'New Invoice', --Added by SM-Rackspace as per #1244069 16-Oct-2018
                            'Please see the attached PDF for a new invoice for '||rec.party_name||'.',
                            'accountsreceivable@arglobal.com');
                commit;
                
                IF vReqEmail = 0
                    THEN
                    vDebug := '050';
                    retcode := '1';
                    vRetstring := vRetstring || rec.party_name;
                    errbuf := '*** The request to email the invoice failed ... '||vRetstring;
          /*       ELSE   -- in case we need to wait for the email to finish before starting the next print program
                    FND_FILE.PUT_LINE(FND_FILE.LOG, errbuf||' - '||rec.email);
                    LOOP -- wait for email to finish before going to next invoice 
                      l_req_return_status :=
                         fnd_concurrent.wait_for_request (request_id      => vReq
                                            ,INTERVAL        => 10 -- 10 seconds
                                            ,max_wait        => 180 -- 3 minutes
                                             -- out arguments
                                            ,phase           => lc_phase
                                            ,STATUS          => lc_status
                                            ,dev_phase       => lc_dev_phase
                                            ,dev_status      => lc_dev_status
                                            ,message         => lc_message
                                            );                        
                        EXIT
                        WHEN UPPER (lc_phase) = 'COMPLETED' OR UPPER (lc_status) IN ('CANCELLED', 'ERROR', 'TERMINATED');
                     END LOOP; */
                   END IF;                 
                 END IF; 
              
            END IF;
        END LOOP;
        if vDebug is null then null; end if; -- removed compilation hint

    EXCEPTION WHEN others THEN
        vErr := SUBSTR(SQLERRM, 1, 2000);
        retcode := '2';
        errbuf := vErr;
    END;
    
PROCEDURE find_invoices_arx (retcode IN OUT VARCHAR2, errbuf IN OUT VARCHAR2) IS
        vDebug     VARCHAR2(10);
        vRetstring VARCHAR2(150) := 'New invoices were found for the the following customers but could not be sent: ';
        vReq       NUMBER;
        vReqEmail  NUMBER;
        vErr       VARCHAR2(2000);
--        l_item_key VARCHAR2(20);
        vOpt        BOOLEAN;
        vToAddress VARCHAR2(100);
        vReq2       NUMBER;
        vLayout     BOOLEAN := TRUE;
        lc_phase            VARCHAR2(50);
        lc_status           VARCHAR2(50);
        lc_dev_phase        VARCHAR2(50);
        lc_dev_status       VARCHAR2(50);
        lc_message          VARCHAR2(50);
        l_req_return_status BOOLEAN;

    BEGIN
    
        -- Added 13-JUL-12 M.H. 
        -- Use profile option for "To" address.
        vToAddress := FND_PROFILE.VALUE_SPECIFIC
                        (name => 'ADRE_EMAIL_INVOICE',
                        user_id => FND_GLOBAL.USER_ID,
                        responsibility_id => NULL,
                        application_id => NULL,
                        org_id => NULL,
                        server_id => NULL); 
                        
        -- Changed 11-OCT-12 M.H.
        -- Removed DISTINCT and added ct.trx_number
        -- So will send seperate PDF invoices
        
        vDebug := '010';
        retcode := '0';
        FND_FILE.PUT_LINE(FND_FILE.LOG, 'New Invoices found for the following customers:');
        FOR rec IN (SELECT ct.sold_to_customer_id,
                           raa_bill_loc.address2 email,
                           hp.party_name,
                           raa_bill_loc.location_id,
                           CT.TRX_NUMBER
                      FROM ra_customer_trx_all ct,
                           hz_cust_accounts rac_bill,
                           hz_parties hp,
                           hz_cust_acct_sites_all raa_bill,
                           hz_party_sites raa_bill_ps,
                           hz_locations raa_bill_loc,
                           hz_cust_site_uses_all su_bill,
                           ra_terms_lines tl
                     WHERE ct.bill_to_site_use_id = su_bill.site_use_id
                       AND ct.bill_to_customer_id = rac_bill.cust_account_id
                       AND rac_bill.party_id = hp.party_id
                       AND su_bill.cust_acct_site_id = raa_bill.cust_acct_site_id
                       AND raa_bill.party_site_id = raa_bill_ps.party_site_id
                       AND raa_bill_loc.location_id = raa_bill_ps.location_id
                       AND ct.printing_pending = 'Y'
                       AND ct.COMPLETE_FLAG = 'Y'
                       AND ct.TERM_ID = TL.TERM_ID(+)
                       AND ct.PRINTING_OPTION IN ('PRI', 'REP')
                       AND NVL(TL.SEQUENCE_NUM, 1) > NVL(ct.LAST_PRINTED_SEQUENCE_NUM,0)
                       AND upper(rtrim(ltrim(raa_bill_loc.address1))) = 'DO NOT MAIL'
                       AND ct.org_id = 424)
                       
        LOOP
            vDebug := '020';
            FND_FILE.PUT_LINE(FND_FILE.LOG, 'Customer (location ID): '||rec.party_name||'('||REC.LOCATION_ID||')');
            FND_FILE.PUT_LINE(FND_FILE.LOG, '--- Invoice: '||rec.trx_number);
            
            vLayout := FND_REQUEST.add_layout ('XBOL', 'ADRE_RAXINV_SEL_CUST','en','US','PDF'); /* LP of Tier1 Set XML layout */
            vOpt :=fnd_request.set_print_options 
                 (copies     =>1);  -- LP of Tier1 added when we decided to dispense with step 3.
            vReq := FND_REQUEST.submit_request(
                            'XBOL',
                    --       'ADRE_RAXINV_SEL_NEW',
                           'ADRE_RAXINV_SEL_CUST',
                            rec.party_name||' - New Invoices Emailed',
                            NULL,
                            FALSE,
                            'TRX_NUMBER', -- p_order_by
                            NULL,
                            NULL,
                            rec.trx_number, --NULL,M.H. 11-OCT-12
                            rec.trx_number, --NULL,M.H. 11-OCT-12
                            NULL,
                            NULL,
                            NULL,
                            NULL, --rec.sold_to_customer_id, --p_customer_id,M.H. 11-OCT-12
                            NULL,
                            'N', --'Y', --p_open_invoice. Must be N for zero dollar invoices
                            'N', --p_check_for_taxyn
                            NULL,
                            'NEW', --p_choice
                            1, --p_header_pages
                            'N', --p_debug_flag
                            10, --p_message_level
                            NULL,
                            NULL,
                            rec.location_id
                             );
                commit;
                
           IF vReq = 0
            THEN
                 vDebug := '030';
                 retcode := '1';
                 vRetstring := vRetstring || rec.party_name;
                 ERRBUF := vRetstring;

           ELSE -- Run email program after waiting for successful finish
            
              LOOP -- wait for invoice print program to finish 
                 l_req_return_status :=
                 fnd_concurrent.wait_for_request (request_id      => vReq
                                            ,INTERVAL        => 10 -- 10 seconds
                                            ,max_wait        => 180 -- 3 minutes
                                             -- out arguments
                                            ,phase           => lc_phase
                                            ,STATUS          => lc_status
                                            ,dev_phase       => lc_dev_phase
                                            ,dev_status      => lc_dev_status
                                            ,message         => lc_message
                                            );                        
                 EXIT
                 WHEN UPPER (lc_phase) = 'COMPLETED' OR UPPER (lc_status) IN ('CANCELLED', 'ERROR', 'TERMINATED');
              END LOOP; 
    --
    --
              IF UPPER (lc_phase) = 'COMPLETED' AND UPPER (lc_status) = 'ERROR' THEN
                 FND_FILE.PUT_LINE(FND_FILE.LOG,'**** The ADRE_RAXINV_SEL_CUST program completed in error. Oracle request id: '||vReq ||' '||SQLERRM);
              ELSIF UPPER (lc_phase) = 'COMPLETED' AND UPPER (lc_status) = 'NORMAL' THEN
                FND_FILE.PUT_LINE(FND_FILE.LOG, '--- ADRE_RAXINV_SEL_CUST request successful for request id: ' || vReq); -- Run email program
                
                vDebug := '040';
                FND_FILE.PUT_LINE(FND_FILE.LOG, '--- Email to ' || rec.party_name ||': '||rec.email);
                ----   Add codeto set print options
                vOpt :=fnd_request.set_print_options 
                 (copies     =>0);
                  ----

                vReqEmail := FND_REQUEST.submit_request(
                            'XBOL',
                           'ADRE_EMAIL_OUTPUT',
                            'Email Invoice to: ' ||rec.email,
                            TO_CHAR(SYSDATE+.010,'DD-MON-YY HH24:MI:SS'),  --12/18 dlf - changed to ~14 minutes was about 7 minutes (.005).  Was 5 .004
                            FALSE,
                            vReq,
                            rec.email||' ;accountsreceivable@arglobal.com', -- use rec.email for automatic email. Use vToAddress (Profile option) to send internally. 
                            'INVOICE',
                            --'New Invoices for '||rec.party_name, --old subject line
                            --rec.email, --Commented by SM-Rackspace as per #1244069 16-Oct-2018
							'New Invoice', --Added by SM-Rackspace as per #1244069 16-Oct-2018
                            'Please see the attached PDF for a new invoice for '||rec.party_name||'.',
                            'accountsreceivable@arglobal.com');
                commit;
                
                IF vReqEmail = 0
                    THEN
                    vDebug := '050';
                    retcode := '1';
                    vRetstring := vRetstring || rec.party_name;
                    errbuf := '*** The request to email the invoice failed ... '||vRetstring;
          /*       ELSE   -- in case we need to wait for the email to finish before starting the next print program
                    FND_FILE.PUT_LINE(FND_FILE.LOG, errbuf||' - '||rec.email);
                    LOOP -- wait for email to finish before going to next invoice 
                      l_req_return_status :=
                         fnd_concurrent.wait_for_request (request_id      => vReq
                                            ,INTERVAL        => 10 -- 10 seconds
                                            ,max_wait        => 180 -- 3 minutes
                                             -- out arguments
                                            ,phase           => lc_phase
                                            ,STATUS          => lc_status
                                            ,dev_phase       => lc_dev_phase
                                            ,dev_status      => lc_dev_status
                                            ,message         => lc_message
                                            );                        
                        EXIT
                        WHEN UPPER (lc_phase) = 'COMPLETED' OR UPPER (lc_status) IN ('CANCELLED', 'ERROR', 'TERMINATED');
                     END LOOP; */
                   END IF;                 
                 END IF; 
              
            END IF;
        END LOOP;
        if vDebug is null then null; end if; -- removed compilation hint

    EXCEPTION WHEN others THEN
        vErr := SUBSTR(SQLERRM, 1, 2000);
        retcode := '2';
        errbuf := vErr;
    END;
END;