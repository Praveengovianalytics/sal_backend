"""eKYC / document-checklist adapter (stub). Cloud: PRVS/eKYC verification service."""

_CHECKLIST = {
    "recon": ["Verify NRIC/FIN (eKYC)", "Confirm contract owner", "Capture e-signature"],
    "ga": ["Verify NRIC/FIN (eKYC)", "Proof of address", "Capture e-signature"],
    "port_in": ["Verify NRIC/FIN (eKYC)", "Donor network account number", "Capture e-signature"],
}

def checklist(scenario: str) -> list[str]:
    return _CHECKLIST.get(scenario, ["Verify NRIC/FIN (eKYC)", "Capture e-signature"])
