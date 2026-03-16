// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title GovernmentBondPlatform
 * @author Student 1
 * @notice Tokenized government bond issuance, verification, purchase, and redemption platform.
 * @dev Uses ERC-1155 multi-token standard. Each bond issuance maps to a unique token id.
 *      Units within the same issuance are fungible (like shares of the same bond series),
 *      while multiple bond issuances coexist efficiently in one contract.
 *
 *      Architecture Decision — Why ERC-1155:
 *      ─────────────────────────────────────
 *      • ERC-20 would require deploying a separate contract per bond issuance — costly and complex.
 *      • ERC-721 treats every single bond unit as unique, which is incorrect for fungible bond units
 *        within the same issuance and wastes gas on per-unit metadata.
 *      • ERC-1155 allows multiple token types (one per bond issuance) in a single contract.
 *        Units of the same bond are fungible with each other, while different bond series
 *        remain distinct. This perfectly models real-world government bond issuances.
 *
 *      Security: OpenZeppelin AccessControl + ReentrancyGuard + Pausable.
 *      Gas:      Custom errors, calldata params, struct packing, minimal storage writes.
 */

// ──────────────────────────────────────────────────────────────────────────────
//  OpenZeppelin v5 imports (compatible with Solidity ^0.8.20)
// ──────────────────────────────────────────────────────────────────────────────
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract GovernmentBondPlatform is ERC1155, AccessControl, Pausable, ReentrancyGuard {

    // ═════════════════════════════════════════════════════════════════════════
    //                               ROLES
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Role for government / authorized bond issuers
    bytes32 public constant ISSUER_ROLE    = keccak256("ISSUER_ROLE");
    /// @notice Role for document / record verifiers
    bytes32 public constant VERIFIER_ROLE  = keccak256("VERIFIER_ROLE");
    /// @notice Role for auditors / regulators performing oversight
    bytes32 public constant AUDITOR_ROLE   = keccak256("AUDITOR_ROLE");

    // ═════════════════════════════════════════════════════════════════════════
    //                               ENUMS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Lifecycle status of a bond issuance
    enum BondStatus {
        ACTIVE,     // 0 — open for purchase
        PAUSED,     // 1 — temporarily suspended
        MATURED,    // 2 — maturity date reached
        REDEEMED,   // 3 — fully redeemed
        CLOSED      // 4 — administratively closed
    }

    /// @notice Categories of off-chain documents registered on-chain via hash
    enum DocumentType {
        PROSPECTUS,       // 0
        LEGAL_APPROVAL,   // 1
        CERTIFICATE,      // 2
        TERMS             // 3
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                           CUSTOM ERRORS
    // ═════════════════════════════════════════════════════════════════════════
    // Gas optimization: custom errors cost less gas than revert strings

    error BondAlreadyExists(uint256 bondId);
    error BondDoesNotExist(uint256 bondId);
    error InvalidDateRange();
    error InvalidSupply();
    error InvalidPrice();
    error InvalidAddress();
    error InvalidAmount();
    error BondNotActive(uint256 bondId);
    error BondPaused(uint256 bondId);
    error BondMatured(uint256 bondId);
    error InsufficientRemainingSupply(uint256 requested, uint256 available);
    error IncorrectPayment(uint256 expected, uint256 received);
    error BondNotMatured(uint256 bondId);
    error InsufficientHolding(uint256 requested, uint256 available);
    error InvalidStatusTransition();
    error NoFundsAvailable();
    error EmptyHashNotAllowed();
    error AccessDenied();

    // ═════════════════════════════════════════════════════════════════════════
    //                              STRUCTS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice On-chain representation of a government bond issuance.
     * @dev `bondId` also serves as the ERC-1155 token id.
     *      `couponRateBps` stores the annual coupon rate in basis points
     *      (e.g. 750 = 7.50%) to avoid floating-point issues.
     *      `exists` flag prevents zero-default confusion.
     */
    struct Bond {
        uint256 bondId;
        string  bondName;
        string  issuerName;
        uint256 faceValue;        // face value in smallest currency unit
        uint256 couponRateBps;    // basis points, e.g. 750 = 7.50%
        uint256 issueDate;        // UNIX timestamp
        uint256 maturityDate;     // UNIX timestamp
        uint256 tokenPriceWei;    // price per bond unit in wei
        uint256 maxSupply;        // total units available
        uint256 unitsSold;        // units already sold
        string  currencyLabel;    // display label, e.g. "ETH" or "ZAR"
        BondStatus status;
        address issuerWallet;     // wallet of the authorized issuer
        bool    exists;           // existence flag
    }

    /**
     * @notice Parameters struct for bond creation — avoids stack-too-deep.
     * @dev Passed as calldata for gas efficiency.
     */
    struct BondCreationParams {
        uint256 bondId;
        string  bondName;
        string  issuerName;
        uint256 faceValue;
        uint256 couponRateBps;
        uint256 issueDate;
        uint256 maturityDate;
        uint256 tokenPriceWei;
        uint256 maxSupply;
        string  currencyLabel;
        address issuerWallet;
    }

    /**
     * @notice Stores cryptographic hashes of off-chain bond documents.
     * @dev Each field stores a keccak256 or SHA-256 derived bytes32 hash.
     *      Zero value means no document registered for that type.
     */
    struct DocumentHashes {
        bytes32 prospectusHash;
        bytes32 legalApprovalHash;
        bytes32 certificateHash;
        bytes32 termsHash;
    }

    /**
     * @notice Tracks per-investor purchase and redemption quantities per bond.
     */
    struct InvestorPosition {
        uint256 purchased;
        uint256 redeemed;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          STATE VARIABLES
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev bondId => Bond struct
    mapping(uint256 => Bond) private bonds;

    /// @dev bondId => DocumentHashes struct
    mapping(uint256 => DocumentHashes) private bondDocuments;

    /// @dev bondId => investor address => InvestorPosition
    mapping(uint256 => mapping(address => InvestorPosition)) private investorPositions;

    /// @dev Array of all bond ids for enumeration by frontend
    uint256[] private allBondIds;

    /// @dev Stored base metadata URI
    string private contractMetadataURI;

    // ═════════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═════════════════════════════════════════════════════════════════════════
    // Comprehensive events form the IMMUTABLE AUDIT TRAIL.
    // Indexed parameters enable efficient log filtering by frontends.

    /// @notice Emitted when a new bond issuance is created
    event BondIssued(
        uint256 indexed bondId,
        string  bondName,
        string  issuerName,
        uint256 faceValue,
        uint256 couponRateBps,
        uint256 issueDate,
        uint256 maturityDate,
        uint256 tokenPriceWei,
        uint256 maxSupply,
        string  currencyLabel,
        address indexed issuerWallet
    );

    /// @notice Emitted when a document hash is registered or updated for a bond
    event BondDocumentHashRegistered(
        uint256 indexed bondId,
        DocumentType indexed docType,
        bytes32 indexed documentHash,
        address registeredBy
    );

    /// @notice Emitted when a bond's lifecycle status changes
    event BondStatusChanged(
        uint256 indexed bondId,
        BondStatus previousStatus,
        BondStatus newStatus,
        address changedBy
    );

    /// @notice Emitted when an investor purchases bond units
    event BondPurchased(
        uint256 indexed bondId,
        address indexed investor,
        uint256 amount,
        uint256 totalCostWei
    );

    /// @notice Emitted when an investor redeems matured bond units
    event BondRedeemed(
        uint256 indexed bondId,
        address indexed investor,
        uint256 amount,
        uint256 redemptionValue,
        uint256 timestamp
    );

    /// @notice Emitted when a verifier/auditor performs a bond record verification
    event BondVerified(
        uint256 indexed bondId,
        address indexed verifier,
        bool    bondExists,
        BondStatus status,
        bool    matured
    );

    /// @notice Emitted when admin withdraws collected Ether
    event FundsWithdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when a document hash verification is performed
    event DocumentHashVerificationPerformed(
        uint256 indexed bondId,
        DocumentType indexed docType,
        bytes32 submittedHash,
        bool    matched,
        address indexed verifier
    );

    // ═════════════════════════════════════════════════════════════════════════
    //                            CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initializes the platform with metadata URI and grants all roles to admin.
     * @param _baseURI  Base metadata URI for ERC-1155 token ids.
     * @param _admin    Address that receives DEFAULT_ADMIN_ROLE and initial role set.
     */
    constructor(string memory _baseURI, address _admin) ERC1155(_baseURI) {
        if (_admin == address(0)) revert InvalidAddress();

        contractMetadataURI = _baseURI;

        // Grant all roles to deployer/admin for demo convenience
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ISSUER_ROLE,        _admin);
        _grantRole(VERIFIER_ROLE,      _admin);
        _grantRole(AUDITOR_ROLE,       _admin);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                             MODIFIERS
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Reverts if bond with given id does not exist
    modifier bondMustExist(uint256 bondId) {
        if (!bonds[bondId].exists) revert BondDoesNotExist(bondId);
        _;
    }

    /// @dev Reverts if caller lacks all three privileged roles
    modifier onlyPrivileged() {
        if (
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender) &&
            !hasRole(VERIFIER_ROLE,      msg.sender) &&
            !hasRole(AUDITOR_ROLE,       msg.sender)
        ) {
            revert AccessDenied();
        }
        _;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                       ADMIN / CONFIGURATION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Updates the base URI for ERC-1155 token metadata.
     * @param newuri New metadata URI string.
     */
    function setURI(string calldata newuri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setURI(newuri);
        contractMetadataURI = newuri;
    }

    /**
     * @notice Returns the stored base metadata URI.
     */
    function getBaseURI() external view returns (string memory) {
        return contractMetadataURI;
    }

    /**
     * @notice Pause the entire platform (emergency circuit breaker).
     */
    function pausePlatform() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the platform after an emergency.
     */
    function unpausePlatform() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Withdraw all collected Ether from bond purchases.
     * @param to Destination wallet address.
     * @dev Protected by reentrancy guard and admin-only access.
     */
    function withdrawFunds(address payable to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert InvalidAddress();

        uint256 amount = address(this).balance;
        if (amount == 0) revert NoFundsAvailable();

        // Low-level call for safe Ether transfer
        (bool success, ) = to.call{value: amount}("");
        require(success, "Withdrawal failed");

        emit FundsWithdrawn(to, amount);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                        BOND ISSUANCE LOGIC
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Creates a new government bond issuance.
     * @dev Bond id becomes the ERC-1155 token id. Uses calldata struct to
     *      avoid stack-too-deep and reduce calldata decoding gas.
     * @param params BondCreationParams struct with all bond metadata.
     */
    function createBondIssuance(BondCreationParams calldata params)
        external
        onlyRole(ISSUER_ROLE)
        whenNotPaused
    {
        // ── Input validation ──
        if (bonds[params.bondId].exists) revert BondAlreadyExists(params.bondId);
        if (params.maturityDate <= params.issueDate) revert InvalidDateRange();
        if (params.maxSupply == 0) revert InvalidSupply();
        if (params.tokenPriceWei == 0) revert InvalidPrice();
        if (params.issuerWallet == address(0)) revert InvalidAddress();

        // ── Single storage write for the entire struct ──
        bonds[params.bondId] = Bond({
            bondId:        params.bondId,
            bondName:      params.bondName,
            issuerName:    params.issuerName,
            faceValue:     params.faceValue,
            couponRateBps: params.couponRateBps,
            issueDate:     params.issueDate,
            maturityDate:  params.maturityDate,
            tokenPriceWei: params.tokenPriceWei,
            maxSupply:     params.maxSupply,
            unitsSold:     0,
            currencyLabel: params.currencyLabel,
            status:        BondStatus.ACTIVE,
            issuerWallet:  params.issuerWallet,
            exists:        true
        });

        // Track bond id for enumeration
        allBondIds.push(params.bondId);

        // ── Audit trail ──
        emit BondIssued(
            params.bondId,
            params.bondName,
            params.issuerName,
            params.faceValue,
            params.couponRateBps,
            params.issueDate,
            params.maturityDate,
            params.tokenPriceWei,
            params.maxSupply,
            params.currencyLabel,
            params.issuerWallet
        );
    }

    /**
     * @notice Manually update bond lifecycle status.
     * @dev Accessible by Admin, Verifier, or Auditor roles for regulatory control.
     * @param bondId  The bond issuance id.
     * @param newStatus The target BondStatus enum value.
     */
    function setBondStatus(uint256 bondId, BondStatus newStatus)
        external
        bondMustExist(bondId)
        onlyPrivileged
    {
        Bond storage bond = bonds[bondId];
        BondStatus previous = bond.status;

        if (previous == newStatus) revert InvalidStatusTransition();

        bond.status = newStatus;

        emit BondStatusChanged(bondId, previous, newStatus, msg.sender);
    }

    /**
     * @notice Marks a bond as matured if block.timestamp >= maturityDate.
     * @dev Useful for demo — an admin/verifier can trigger maturity explicitly.
     * @param bondId The bond issuance id.
     */
    function markBondAsMatured(uint256 bondId)
        external
        bondMustExist(bondId)
        onlyPrivileged
    {
        Bond storage bond = bonds[bondId];
        if (block.timestamp < bond.maturityDate) revert BondNotMatured(bondId);

        BondStatus previous = bond.status;
        bond.status = BondStatus.MATURED;

        emit BondStatusChanged(bondId, previous, BondStatus.MATURED, msg.sender);
    }

    /**
     * @notice Pause a specific bond issuance (admin only).
     * @param bondId The bond issuance id.
     */
    function pauseBond(uint256 bondId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        bondMustExist(bondId)
    {
        Bond storage bond = bonds[bondId];
        BondStatus previous = bond.status;
        bond.status = BondStatus.PAUSED;

        emit BondStatusChanged(bondId, previous, BondStatus.PAUSED, msg.sender);
    }

    /**
     * @notice Reactivate a paused bond issuance (admin only).
     * @param bondId The bond issuance id.
     */
    function activateBond(uint256 bondId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        bondMustExist(bondId)
    {
        Bond storage bond = bonds[bondId];
        BondStatus previous = bond.status;
        bond.status = BondStatus.ACTIVE;

        emit BondStatusChanged(bondId, previous, BondStatus.ACTIVE, msg.sender);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                     DOCUMENT HASH REGISTRATION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Registers or updates a cryptographic hash for a bond document.
     * @dev Only ISSUER_ROLE can register. This implements the "registration using
     *      cryptographic hash and metadata" requirement for Student 1.
     * @param bondId       The bond issuance id.
     * @param docType      Category of document (PROSPECTUS, LEGAL_APPROVAL, etc.).
     * @param documentHash keccak256 or SHA-256 derived hash as bytes32.
     */
    function registerDocumentHash(
        uint256      bondId,
        DocumentType docType,
        bytes32      documentHash
    )
        external
        onlyRole(ISSUER_ROLE)
        bondMustExist(bondId)
        whenNotPaused
    {
        if (documentHash == bytes32(0)) revert EmptyHashNotAllowed();

        DocumentHashes storage docs = bondDocuments[bondId];

        // Gas: direct field assignment instead of array operations
        if (docType == DocumentType.PROSPECTUS) {
            docs.prospectusHash = documentHash;
        } else if (docType == DocumentType.LEGAL_APPROVAL) {
            docs.legalApprovalHash = documentHash;
        } else if (docType == DocumentType.CERTIFICATE) {
            docs.certificateHash = documentHash;
        } else if (docType == DocumentType.TERMS) {
            docs.termsHash = documentHash;
        }

        emit BondDocumentHashRegistered(bondId, docType, documentHash, msg.sender);
    }

    /**
     * @notice Returns all registered document hashes for a bond.
     * @param bondId The bond issuance id.
     * @return prospectusHash     Hash of the bond prospectus document.
     * @return legalApprovalHash  Hash of the legal approval document.
     * @return certificateHash    Hash of the bond certificate document.
     * @return termsHash          Hash of the terms and conditions document.
     */
    function getBondDocumentHashes(uint256 bondId)
        external
        view
        bondMustExist(bondId)
        returns (
            bytes32 prospectusHash,
            bytes32 legalApprovalHash,
            bytes32 certificateHash,
            bytes32 termsHash
        )
    {
        DocumentHashes storage docs = bondDocuments[bondId];
        return (
            docs.prospectusHash,
            docs.legalApprovalHash,
            docs.certificateHash,
            docs.termsHash
        );
    }

    /**
     * @notice Verifies whether a submitted hash matches the on-chain registered hash.
     * @dev Pure view function — no state change, no gas cost when called externally.
     *      This implements the "verification mechanisms" requirement for Student 1.
     * @param bondId        The bond issuance id.
     * @param submittedHash The hash to verify against the stored record.
     * @param docType       The document category to check.
     * @return matched      True if the submitted hash equals the stored hash.
     */
    function verifyDocumentHash(
        uint256      bondId,
        bytes32      submittedHash,
        DocumentType docType
    )
        public
        view
        bondMustExist(bondId)
        returns (bool matched)
    {
        DocumentHashes storage docs = bondDocuments[bondId];

        if (docType == DocumentType.PROSPECTUS) {
            matched = (docs.prospectusHash == submittedHash);
        } else if (docType == DocumentType.LEGAL_APPROVAL) {
            matched = (docs.legalApprovalHash == submittedHash);
        } else if (docType == DocumentType.CERTIFICATE) {
            matched = (docs.certificateHash == submittedHash);
        } else if (docType == DocumentType.TERMS) {
            matched = (docs.termsHash == submittedHash);
        }
    }

    /**
     * @notice Verifies a document hash and emits an audit event.
     * @dev State-changing version for auditors who need on-chain proof of verification.
     * @param bondId        The bond issuance id.
     * @param submittedHash The hash to verify.
     * @param docType       The document category.
     * @return matched      True if the hash matches.
     */
    function verifyDocumentHashWithAudit(
        uint256      bondId,
        bytes32      submittedHash,
        DocumentType docType
    )
        external
        bondMustExist(bondId)
        onlyPrivileged
        returns (bool matched)
    {
        matched = verifyDocumentHash(bondId, submittedHash, docType);

        emit DocumentHashVerificationPerformed(
            bondId,
            docType,
            submittedHash,
            matched,
            msg.sender
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                      PURCHASE / MARKET LOGIC
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Purchase units of a bond issuance using native ETH.
     * @dev Payment model: native ETH on local/test chain for Hardhat demo simplicity.
     *      In production, a stablecoin (ERC-20) payment module would replace this.
     *      The exact ETH amount must match tokenPriceWei * amount.
     *
     *      Security: ReentrancyGuard prevents reentrancy on mint.
     *      Gas: Checks-effects-interactions pattern; minimal storage writes.
     *
     * @param bondId The bond issuance id.
     * @param amount Number of bond units to purchase.
     */
    function buyBond(uint256 bondId, uint256 amount)
        external
        payable
        nonReentrant
        whenNotPaused
        bondMustExist(bondId)
    {
        if (amount == 0) revert InvalidAmount();

        Bond storage bond = bonds[bondId];

        // Automatic maturity check — prevents purchase of matured bonds
        if (block.timestamp >= bond.maturityDate) revert BondMatured(bondId);

        // Status checks with specific error messages
        if (bond.status == BondStatus.PAUSED) revert BondPaused(bondId);
        if (bond.status != BondStatus.ACTIVE)  revert BondNotActive(bondId);

        // Supply check
        uint256 remainingSupply = bond.maxSupply - bond.unitsSold;
        if (amount > remainingSupply) {
            revert InsufficientRemainingSupply(amount, remainingSupply);
        }

        // Payment validation
        uint256 totalCost = bond.tokenPriceWei * amount;
        if (msg.value != totalCost) {
            revert IncorrectPayment(totalCost, msg.value);
        }

        // ── Effects (before interaction) ──
        bond.unitsSold += amount;
        investorPositions[bondId][msg.sender].purchased += amount;

        // ── Interaction ──
        _mint(msg.sender, bondId, amount, "");

        // ── Audit trail ──
        emit BondPurchased(bondId, msg.sender, amount, totalCost);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                     MATURITY / REDEMPTION LOGIC
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Redeem matured bond units.
     * @dev Burns the investor's ERC-1155 tokens and records the redemption.
     *      For demo purposes, the redemption value is calculated as
     *      faceValue * amount (representing par value return at maturity).
     *      In a production system, actual Ether/stablecoin payout would occur here.
     *
     * @param bondId The bond issuance id.
     * @param amount Number of bond units to redeem.
     */
    function redeemBond(uint256 bondId, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        bondMustExist(bondId)
    {
        if (amount == 0) revert InvalidAmount();

        Bond storage bond = bonds[bondId];

        // Must be matured (either by time or by admin marking)
        if (!_isBondMatured(bondId)) revert BondNotMatured(bondId);

        InvestorPosition storage position = investorPositions[bondId][msg.sender];
        uint256 availableHolding = position.purchased - position.redeemed;

        if (amount > availableHolding) {
            revert InsufficientHolding(amount, availableHolding);
        }

        // ── Effects ──
        position.redeemed += amount;

        // ── Interaction — burn the redeemed tokens ──
        _burn(msg.sender, bondId, amount);

        // Calculate redemption value for audit trail (faceValue * units)
        uint256 redemptionValue = bond.faceValue * amount;

        // ── Audit trail ──
        emit BondRedeemed(bondId, msg.sender, amount, redemptionValue, block.timestamp);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                      VERIFICATION FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check whether a bond issuance exists.
     * @param bondId The bond issuance id.
     * @return True if the bond has been created.
     */
    function bondExistsCheck(uint256 bondId) external view returns (bool) {
        return bonds[bondId].exists;
    }

    /**
     * @notice Returns the full Bond struct for frontend display.
     * @param bondId The bond issuance id.
     * @return The Bond struct with all metadata fields.
     */
    function getBondDetails(uint256 bondId)
        external
        view
        bondMustExist(bondId)
        returns (Bond memory)
    {
        return bonds[bondId];
    }

    /**
     * @notice Returns the current lifecycle status of a bond.
     * @param bondId The bond issuance id.
     * @return The BondStatus enum value.
     */
    function getBondStatus(uint256 bondId)
        public
        view
        bondMustExist(bondId)
        returns (BondStatus)
    {
        return bonds[bondId].status;
    }

    /**
     * @notice Returns remaining purchasable supply for a bond.
     * @param bondId The bond issuance id.
     * @return Remaining units available for purchase.
     */
    function getRemainingSupply(uint256 bondId)
        public
        view
        bondMustExist(bondId)
        returns (uint256)
    {
        Bond storage bond = bonds[bondId];
        return bond.maxSupply - bond.unitsSold;
    }

    /**
     * @notice Check whether a bond has reached maturity based on block timestamp.
     * @param bondId The bond issuance id.
     * @return True if current time >= maturityDate.
     */
    function isBondMatured(uint256 bondId)
        public
        view
        bondMustExist(bondId)
        returns (bool)
    {
        return _isBondMatured(bondId);
    }

    /**
     * @notice Check whether a bond is eligible for redemption.
     * @dev A bond is redeemable if it has matured (by time or status).
     * @param bondId The bond issuance id.
     * @return True if the bond can be redeemed.
     */
    function isBondRedeemable(uint256 bondId)
        external
        view
        bondMustExist(bondId)
        returns (bool)
    {
        return _isBondMatured(bondId);
    }

    /**
     * @notice Returns investor's purchased, redeemed, and active holding for a bond.
     * @param bondId   The bond issuance id.
     * @param investor The investor's wallet address.
     * @return purchased     Total units ever purchased.
     * @return redeemed      Total units redeemed.
     * @return activeHolding Current unredeemed balance.
     */
    function getInvestorHolding(uint256 bondId, address investor)
        public
        view
        bondMustExist(bondId)
        returns (
            uint256 purchased,
            uint256 redeemed,
            uint256 activeHolding
        )
    {
        InvestorPosition storage position = investorPositions[bondId][investor];
        purchased     = position.purchased;
        redeemed      = position.redeemed;
        activeHolding = purchased - redeemed;
    }

    /**
     * @notice Check whether an investor currently holds active units of a bond.
     * @param bondId   The bond issuance id.
     * @param investor The investor's wallet address.
     * @return True if investor has unredeemed bond units.
     */
    function investorOwnsBond(uint256 bondId, address investor)
        external
        view
        bondMustExist(bondId)
        returns (bool)
    {
        (, , uint256 activeHolding) = getInvestorHolding(bondId, investor);
        return activeHolding > 0;
    }

    /**
     * @notice Returns all bond ids that have been created.
     * @dev Enables frontend enumeration of available bonds.
     * @return Array of bond ids.
     */
    function getAllBondIds() external view returns (uint256[] memory) {
        return allBondIds;
    }

    /**
     * @notice Emits a verification event for a bond record (audit/dashboard use).
     * @dev State-changing function so the verification is recorded on-chain.
     *      Only accessible by Verifier, Auditor, or Admin roles.
     * @param bondId The bond issuance id.
     */
    function verifyBondRecord(uint256 bondId)
        external
        bondMustExist(bondId)
        onlyPrivileged
    {
        bool exists_  = bonds[bondId].exists;
        BondStatus status_ = bonds[bondId].status;
        bool matured_ = _isBondMatured(bondId);

        emit BondVerified(bondId, msg.sender, exists_, status_, matured_);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                      INTERNAL HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @dev Internal maturity check — considers both timestamp and status.
     *      A bond is considered matured if block.timestamp >= maturityDate
     *      OR if an admin has explicitly set status to MATURED.
     */
    function _isBondMatured(uint256 bondId) internal view returns (bool) {
        return block.timestamp >= bonds[bondId].maturityDate ||
               bonds[bondId].status == BondStatus.MATURED;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                       ERC-1155 OVERRIDES
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Enforces platform pause on single token transfers.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 value,
        bytes memory data
    ) public virtual override whenNotPaused {
        super.safeTransferFrom(from, to, id, value, data);
    }

    /**
     * @notice Enforces platform pause on batch token transfers.
     */
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) public virtual override whenNotPaused {
        super.safeBatchTransferFrom(from, to, ids, values, data);
    }

    /**
     * @notice Resolves supportsInterface for ERC-1155 and AccessControl.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                         RECEIVE ETHER
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Allows contract to receive plain Ether transfers
    receive() external payable {}
}
