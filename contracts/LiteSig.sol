pragma solidity 0.5.8;

/**
 * liteSig is a lighter weight multisig based on https://github.com/christianlundkvist/simple-multisig
 * Owners aggregate signatures offline and then broadcast a transaction with the required number of signatures.
 * Unlike other multisigs, this is meant to have minimal administration functions and other features in order
 * to reduce the footprint and attack surface.
 */
contract liteSig {

    //  Events triggered for incoming and outgoing transactions
    event Deposit(address indexed source, uint value);
    event Execution(uint indexed transactionId, address indexed destination, uint value, bytes data);
    event ExecutionFailure(uint indexed transactionId, address indexed destination, uint value, bytes data);

    // List of owner addresses - for external readers convenience only
    address[] public owners;

    // Mapping of owner address to keep track for lookups
    mapping(address => bool) ownersMap;

    // Nonce increments by one on each broadcast transaction to prevent replays
    uint public nonce = 0;

    // Number of required signatures from the list of owners
    uint public requiredSignatures = 0;

    // EIP712 Precomputed hashes:
    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)")
    bytes32 constant EIP712DOMAINTYPE_HASH = 0xd87cd6ef79d4e2b95e15ce8abf732db51ec771f1ca2edccf22a46c729ac56472;

    // keccak256("liteSig")
    bytes32 constant NAME_HASH = 0xe0f1e1c99009e212fa1e207fccef2ee9432c52bbf5ef25688885ea0cce69531d;

    // keccak256("1")
    bytes32 constant VERSION_HASH = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    // keccak256("MultiSigTransaction(address destination,uint256 value,bytes data,uint256 nonce)")
    bytes32 constant TXTYPE_HASH = 0xe7beff35c01d1bb188c46fbae3d80f308d2600ba612c687a3e61446e0dffda0b;

    // keccak256("TOKENSOFT")
    bytes32 constant SALT = 0x9c360831104e550f13ec032699c5f1d7f17190a31cdaf5c83945a04dfd319eea;

    // Hash for EIP712, computed from data and contract address - ensures it can't be replayed against
    // other contracts or chains
    bytes32 public DOMAIN_SEPARATOR;

    // Track init state
    bool initialized = false;

    // The init function inputs a list of owners and the number of signatures that
    //   are required before a transaction is executed.
    // Owners list must be in ascending address order.
    // Required sigs must be greater than 0 and less than or equal to number of owners.
    // Chain ID prevents replay across chains
    // This function can only be run one time
    function init(address[] memory _owners, uint _requiredSignatures, uint chainId) public {
        // Verify it can't be initialized again
        require(!initialized, "Init function can only be run once");
        initialized = true;

        // Verify the lengths of values being passed in
        require(_owners.length > 0 && _owners.length <= 10, "Owners List min is 1 and max is 10");
        require(
            _requiredSignatures > 0 && _requiredSignatures <= _owners.length,
            "Required signatures must be in the proper range"
        );

        // Verify the owners list is valid and in order
        // No 0 addresses or duplicates
        address lastAdd = address(0);
        for (uint i = 0; i < _owners.length; i++) {
            require(_owners[i] > lastAdd, "Owner addresses must be unique and in order");
            ownersMap[_owners[i]] = true;
            lastAdd = _owners[i];
        }

        // Save off owner list and required sig.
        owners = _owners;
        requiredSignatures = _requiredSignatures;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(EIP712DOMAINTYPE_HASH,
            NAME_HASH,
            VERSION_HASH,
            chainId,
            address(this),
            SALT)
        );
    }

    /**
     * This function is adapted from the OpenZeppelin libarary but instead of passing in bytes
     * array, it already has the sig fields broken down.
     *
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature`. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM opcode allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * (.note) This call _does not revert_ if the signature is invalid, or
     * if the signer is otherwise unable to be retrieved. In those scenarios,
     * the zero address is returned.
     *
     * (.warning) `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise)
     * be too long), and then calling `toEthSignedMessageHash` on it.
     */
    function safeRecover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {

        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (281): 0 < s < secp256k1n ÷ 2 + 1, and for v in (282): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return address(0);
        }

        if (v != 27 && v != 28) {
            return address(0);
        }

        // If the signature is valid (and not malleable), return the signer address
        return ecrecover(hash, v, r, s);
    }

    /**
     * Once the owners of the multisig have signed across the payload, they can submit it to this function.
     * This will verify enough signatures were aggregated and then broadcast the transaction.
     * It can be used to send ETH or trigger a function call against another address (or both).
     *
     * Signatures must be in the correct ascending order (according to associated addresses)
     */
    function submit(
        uint8[] memory sigV,
        bytes32[] memory sigR,
        bytes32[] memory sigS,
        address destination,
        uint value,
        bytes memory data
    ) public returns (bool)
    {
        // Verify initialized
        require(initialized, "Initialization must be complete");

        // Verify signature lengths
        require(sigR.length == sigS.length && sigR.length == sigV.length, "Sig arrays not the same lengths");
        require(sigR.length == requiredSignatures, "Signatures list is not the expected length");

        // EIP712 scheme: https://github.com/ethereum/EIPs/blob/master/EIPS/eip-712.md
        // Note that the nonce is always included from the contract state to prevent replay attacks
        bytes32 txInputHash = keccak256(abi.encode(TXTYPE_HASH, destination, value, keccak256(data), nonce));
        bytes32 totalHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, txInputHash));

        // Add in the ETH specific prefix
        bytes memory prefix = "\x19Ethereum Signed Message:\n32";
        bytes32 prefixedHash = keccak256(abi.encodePacked(prefix, totalHash));

        // Iterate and verify signatures are from owners
        address lastAdd = address(0); // cannot have address(0) as an owner
        for (uint i = 0; i < requiredSignatures; i++) {

            // Recover the address from the signature - if anything is wrong, this will return 0
            address recovered = safeRecover(prefixedHash, sigV[i], sigR[i], sigS[i]);

            // Ensure the signature is from an owner address and there are no duplicates
            // Also verifies error of 0 returned
            require(ownersMap[recovered], "Signature must be from an owner");
            require(recovered > lastAdd, "Signature must be unique");
            lastAdd = recovered;
        }

        // Increment the nonce before making external call
        nonce = nonce + 1;
        (bool success, ) = address(destination).call.value(value)(data);
        if(success) {
            emit Execution(nonce, destination, value, data);
        } else {
            emit ExecutionFailure(nonce, destination, value, data);
        }

        return success;
    }

    // Allow ETH to be sent to this contract
    function () external payable {
        emit Deposit(msg.sender, msg.value);
    }

}