// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./Errors.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title SmartEscrow contract
 * @dev Contract to handle payment of OP tokens over a period of vesting with
 * the ability to terminate the contract.
 */
contract SmartEscrow is Ownable2Step {
    event OPTransfered(uint256 amount, address indexed recipient);
    event BeneficiaryOwnerUpdated(address indexed oldOwner, address indexed newOwner);
    event BeneficiaryUpdated(address indexed oldBeneficiary, address indexed newBeneficiary);
    event ContractTerminated();

    IERC20 public constant OP_TOKEN = IERC20(0x4200000000000000000000000000000000000042);

    address public beneficiaryOwner;
    address public beneficiary;
    uint256 public released;
    uint64 public immutable start;
    uint64 public immutable end;
    uint64 public immutable vestingPeriod;
    uint64 private immutable _initialTokens;
    uint64 private immutable  _vestingEventTokens;
    bool public contractTerminated;

    /**
     * @dev Set initial parameters.
     * @param beneficiaryOwnerAddress Address which can update the beneficiary address.
     * @param beneficiaryAddress Address which receives tokens that have vested.
     * @param escrowOwner Address which can terminate the contract.
     * @param startTimestamp Timestamp of the start of vesting period (or the cliff, if there is one).
     * @param endTimestamp Timestamp of the end of the vesting period.
     * @param vestingPeriodSeconds Period of time between each vesting event in seconds.
     * @param numInitialTokens Number of OP tokens which vest at start time.
     * @param numVestingEventTokens Number of OP tokens which vest upon each vesting event.
     */
    constructor(
        address beneficiaryOwnerAddress,
        address beneficiaryAddress,
        address escrowOwner,
        uint64 startTimestamp,
        uint64 endTimestamp,
        uint64 vestingPeriodSeconds,
        uint64 numInitialTokens,
        uint64 numVestingEventTokens
    ) {
        if (beneficiaryOwnerAddress == address(0) || beneficiaryAddress == address(0)) {
            revert AddressIsZeroAddress();
        }
        if (startTimestamp == 0) revert StartTimeIsZero();
        if (startTimestamp > endTimestamp) revert StartTimeAfterEndTime(startTimestamp, endTimestamp);
        if (vestingPeriodSeconds == 0) revert VestingPeriodIsZeroSeconds();

        beneficiary = beneficiaryAddress;
        beneficiaryOwner = beneficiaryOwnerAddress;
        start = startTimestamp;
        end = endTimestamp;
        vestingPeriod = vestingPeriodSeconds;
        _initialTokens = numInitialTokens;
        _vestingEventTokens = numVestingEventTokens;

        _transferOwnership(escrowOwner);
    }

    /**
     * @dev Allow escrow owner (2-of-2 multisig with beneficiary and benefactor
     * owners as signers) to terminate the contract.
     *
     * Emits a {ContractTerminated} event.
     */
    function terminate(address returnAddress) external onlyOwner {
        contractTerminated = true;
        emit ContractTerminated();
        withdrawUnvestedTokens(returnAddress);
    }

    /**
     * @dev Allow contract owner to update beneficiary owner address.
     *
     * Emits a {BeneficiaryOwnerUpdated} event.
     */
    function updateBeneficiaryOwner(address newBeneficiaryOwner) external onlyOwner {
        if (newBeneficiaryOwner == address(0)) revert AddressIsZeroAddress();
        if (beneficiaryOwner != newBeneficiaryOwner) {
            address oldBeneficiaryOwner = beneficiaryOwner;
            beneficiaryOwner = newBeneficiaryOwner;
            emit BeneficiaryUpdated(oldBeneficiaryOwner, newBeneficiaryOwner);
        }
    }

    /**
     * @dev Allow beneficiary owner to update beneficiary address.
     *
     * Emits a {BeneficiaryUpdated} event.
     */
    function updateBeneficiary(address newBeneficiary) external {
        if (msg.sender != beneficiaryOwner) revert CallerIsNotOwner(msg.sender, beneficiaryOwner);
        if (newBeneficiary == address(0)) revert AddressIsZeroAddress();
        if (beneficiary != newBeneficiary) {
            address oldBeneficiary = beneficiary;
            beneficiary = newBeneficiary;
            emit BeneficiaryUpdated(oldBeneficiary, newBeneficiary);
        }
    }

    /**
     * @dev Release OP tokens that have already vested.
     *
     * Emits a {OPTransfered} event.
     */
    function release() public {
        if (contractTerminated == true) revert ContractIsTerminated();
        uint256 amount = releasable();
        released += amount;
        emit OPTransfered(amount, beneficiary);
        SafeERC20.safeTransfer(OP_TOKEN, beneficiary, amount);
    }

    /**
     * @dev Allow withdrawal of remaining tokens to provided address if contract is terminated
     *
     * Emits a {OPTransfered} event.
     */
    function withdrawUnvestedTokens(address returnAddress) public onlyOwner {
        if (contractTerminated == false) revert ContractIsNotTerminated();
        if (returnAddress == address(0)) revert AddressIsZeroAddress();
        uint256 amount = OP_TOKEN.balanceOf(address(this));
        emit OPTransfered(amount, returnAddress);
        SafeERC20.safeTransfer(OP_TOKEN, returnAddress, amount);
    }

    /**
     * @dev Getter for the amount of releasable OP.
     */
    function releasable() public view returns (uint256) {
        return vestedAmount(uint64(block.timestamp)) - released;
    }

    /**
     * @dev Calculates the amount of OP that has already vested.
     */
    function vestedAmount(uint64 timestamp) public view returns (uint256) {
        return _vestingSchedule(OP_TOKEN.balanceOf(address(this)) + released, timestamp);
    }

    /**
     * @dev Returns the amount vested as a function of time.
     */
    function _vestingSchedule(uint256 totalAllocation, uint64 timestamp) internal view returns (uint256) {
        if (timestamp < start) {
            return 0;
        } else if (timestamp > end) {
            return totalAllocation;
        } else {
            return _initialTokens + ((timestamp - start) / vestingPeriod) * _vestingEventTokens;
        }
    }
}
